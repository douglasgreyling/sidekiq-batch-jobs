# frozen_string_literal: true

class SidekiqBatch
  # Scopes a block of `perform_async` calls to one SidekiqBatch, through a
  # thread-local the client middleware reads on every push. Only the enrolling
  # thread is affected; jobs a tracked worker enqueues later are not enrolled.
  class BatchEnrollmentContext
    THREAD_KEY   = :sidekiq_batch_enrollment_context
    TXN_BASELINE = :sidekiq_batch_enrollment_txn_baseline

    class Error < StandardError; end

    class NestedError < Error; end

    class TransactionError < Error; end

    class EmptyEnrollmentError < Error; end

    class AdoptedError < Error; end

    class AlreadyStartedError < Error; end

    def self.current
      Thread.current[THREAD_KEY]
    end

    def self.transaction_baseline
      Thread.current[TXN_BASELINE] || 0
    end

    def initialize(batch)
      @batch          = batch
      @inserted_count = 0
    end

    attr_reader :batch

    def run(&block)
      assert_startable!

      enroll_from(&block)

      if @inserted_count.zero?
        # Nothing to complete, so drop the row rather than leave an orphan
        # `pending` batch behind for callers who rescue the error.
        discard
        raise EmptyEnrollmentError, "jobs {} block enrolled zero jobs"
      end

      raise AdoptedError, "SidekiqBatch ##{@batch.id} was reaped as abandoned while its jobs {} block ran" \
        unless start!(enrollment_error: nil)

      complete_if_finished
    end

    def enroll(payload)
      assert_no_open_transaction!

      # The object, not its id: `belongs_to` is required by default, so an id
      # alone would make ActiveRecord SELECT the batch back on every enrolled job
      # to prove it exists. The object satisfies that check in memory.
      ::SidekiqBatchJob.create!(
        sidekiq_batch: @batch,
        jid:           payload.fetch("jid"),
        worker_class:  payload.fetch("class"),
        args:          payload.fetch("args", []),
        status:        "pending"
      )

      # Lets the server middleware recognise a tracked job without asking
      # Postgres. Sidekiq pushes only after the client chain returns, so this
      # reaches the worker. After the insert, so a failed insert stamps nothing.
      payload[PAYLOAD_BATCH_ID_KEY] = @batch.id

      @inserted_count += 1
    end

    private

    # A separate frame from #with_enrollment_context on purpose. Ruby runs a
    # rescue clause BEFORE the ensure in the same begin, so a rescue written
    # beside the `yield` would finalize the batch with the context still active
    # and enroll its own callbacks into the batch they announce. Here the inner
    # method's ensure has already cleared the thread-local by the time this
    # rescue sees the exception.
    def enroll_from(&block)
      with_enrollment_context(&block)
    rescue StandardError => e
      finalize_partial_enrollment(e)

      raise
    end

    # All three run before the thread-local is set and before #enroll_from, so a
    # rejected call never reaches the disposal paths on a batch it enrolled
    # nothing into.
    def assert_startable!
      raise NestedError, "jobs {} is already active on this thread" if self.class.current

      assert_not_started!

      # Enrollment rows have to be committed before their jobs reach Redis, so a
      # caller's open transaction would break the one-to-one tracking.
      raise TransactionError, "jobs {} cannot be called inside an open ActiveRecord transaction" if in_open_transaction?
    end

    # A batch is enrolled once. A second block would enroll into a batch whose
    # `total_jobs` is already stamped and whose outcome may already have been
    # announced, and both disposal paths below assume the batch is still the
    # caller's to throw away. The in-memory status is enough and costs no query:
    # #start! reloads, so a batch this process started reads `running` here, and
    # one started elsewhere is caught by #start!'s own `pending` qualification.
    def assert_not_started!
      return if @batch.pending_status?

      raise AlreadyStartedError,
            "jobs {} has already run for SidekiqBatch ##{@batch.id} (status `#{@batch.status}`). " \
            "A batch is enrolled once; create a new one rather than reopening it."
    end

    # Qualified on `pending` for the same reason #start! is. The entry guard
    # means the batch was the caller's to discard when the block began, and this
    # keeps that true at the point of deletion: a second enroller racing on the
    # same batch may have started it in between, and a started batch's rows are
    # tracking jobs that are already running. The FK cascades to them.
    def discard
      ::SidekiqBatch.where(id: @batch.id, status: "pending").delete_all
    end

    def with_enrollment_context
      Thread.current[THREAD_KEY] = self

      yield
    ensure
      Thread.current[THREAD_KEY] = nil
    end

    # Conditional on `pending` because AbandonedEnrollmentReaper can adopt a
    # batch that went quiet. An unconditional update would flip an already
    # terminal batch back to `running` with its claim spent, losing its
    # callbacks with no trace for the orphan reaper. One statement, so a
    # completion check cannot land mid-write and judge half a row.
    #
    # @return [Boolean] whether this caller started the batch
    def start!(attrs)
      started = ::SidekiqBatch.where(id: @batch.id, status: "pending").update_all(
        {
          total_jobs: @batch.sidekiq_batch_jobs.count,
          status:     ::SidekiqBatch.statuses.fetch("running"),
          updated_at: Time.current
        }.merge(attrs)
      )

      @batch.reload

      started.positive?
    end

    # Catches the batch whose jobs all finished before the block closed. Nothing
    # else would notice: no worker is left to run the check.
    #
    # It alerts rather than raising because by this point every row is committed
    # and every job is queued, so the enqueue the caller asked for succeeded.
    # Telling them otherwise invites a retry that enqueues the whole batch a
    # second time, to fix a batch that is not broken: it is `running` with
    # accurate rows, and StuckJobReaper runs this same check on any batch that
    # goes quiet. Middleware.check_completion swallows the same failure for the
    # same reason. #start! above is deliberately not covered, because a batch
    # left `pending` really is degraded, and the caller should hear about it.
    def complete_if_finished
      @batch.attempt_completion!
    rescue StandardError => e
      ::Sidekiq::Batch::Jobs.config.alert(
        "SidekiqBatch ##{@batch.id}: jobs {} enrolled #{@inserted_count} job(s) and started the batch, " \
        "but the completion check that follows failed (#{e.class}: #{e.message}). The reaper will pick it up."
      )

      nil
    end

    # Whatever the block enqueued before raising is already running, so the
    # batch has to reach a terminal state rather than sit `pending`, which
    # nothing else looks at. `enrollment_error` makes the outcome honest: no
    # failure policy excuses a batch that was never fully enqueued, so
    # CompletionQuery reads it as an unconditional failure.
    def finalize_partial_enrollment(error)
      # Nothing queued, so nothing to announce. Same disposal as an empty block.
      return discard if @inserted_count.zero?

      start!(enrollment_error: { "class" => error.class.name, "message" => error_message(error) })

      @batch.attempt_completion!
    rescue StandardError => e
      # Never let bookkeeping replace the caller's exception; theirs explains what
      # actually went wrong.
      ::Sidekiq::Batch::Jobs.config.alert(
        "SidekiqBatch ##{@batch.id}: jobs {} raised #{error.class}, and recording that failed too " \
        "(#{e.class}: #{e.message}). The reaper will pick the batch up."
      )
    end

    def error_message(error)
      error.message.to_s.truncate(::Sidekiq::Batch::Jobs.config.error_message_max)
    end

    def assert_no_open_transaction!
      return unless in_open_transaction?

      raise TransactionError, "jobs {} cannot enroll inside an open ActiveRecord transaction"
    end

    def in_open_transaction?
      ::SidekiqBatchJob.connection.open_transactions > self.class.transaction_baseline
    end
  end
end
