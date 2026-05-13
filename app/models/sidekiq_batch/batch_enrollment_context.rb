# frozen_string_literal: true

class SidekiqBatch
  # Scopes a block of `perform_async` calls to a specific SidekiqBatch.
  # Active only on the enrolling thread via a thread-local reference;
  # child jobs spawned at execution time from tracked workers are
  # pass-through (by design).
  #
  # Enrollment itself is performed by `SidekiqBatch::ClientMiddleware`,
  # which looks up the thread-local context during each client push and
  # writes a `SidekiqBatchJob` row BEFORE Sidekiq's `raw_push` sends the
  # job to Redis. The client middleware also sits outermost in the chain
  # so that dedupe/suppression middleware earlier-added get the final
  # say on whether a payload should actually be enrolled.
  class BatchEnrollmentContext
    THREAD_KEY   = :sidekiq_batch_enrollment_context
    TXN_BASELINE = :sidekiq_batch_enrollment_txn_baseline

    class Error < StandardError; end

    class NestedError < Error; end

    class TransactionError < Error; end

    class EmptyEnrollmentError < Error; end

    def self.current
      Thread.current[THREAD_KEY]
    end

    # Specs running inside a fixture transaction set this to the open-txn
    # count at the start of each example; anything above the baseline is
    # a caller-opened transaction and is rejected.
    def self.transaction_baseline
      Thread.current[TXN_BASELINE] || 0
    end

    def initialize(batch)
      @batch          = batch
      @inserted_count = 0
    end

    attr_reader :batch

    def run # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      raise NestedError, "jobs {} is already active on this thread" if self.class.current
      # NOTE: We can't allow the context to work whilst wrapped by a transaction.
      # For the sake of tracking progress correctly we need the state of Redis and the DB to be one to one
      raise TransactionError, "jobs {} cannot be called inside an open ActiveRecord transaction" if in_open_transaction?

      Thread.current[THREAD_KEY] = self

      yield

      if @inserted_count.zero?
        # Empty block means this batch will never have work to complete.
        # Destroy the batch row so callers who rescue the error don't leave
        # orphan `pending` rows lying around forever.
        @batch.destroy
        raise EmptyEnrollmentError, "jobs {} block enrolled zero jobs"
      end

      actual_total = @batch.sidekiq_batch_jobs.count

      @batch.update!(total_jobs: actual_total, status: "running")
      @batch.attempt_completion!
    ensure
      Thread.current[THREAD_KEY] = nil
    end

    # Called by ClientMiddleware after downstream middleware has confirmed
    # the job will be pushed. Insert is committed immediately (no surrounding
    # transaction) so Sidekiq's subsequent raw_push hands off a visible row.
    def enroll(payload)
      ::SidekiqBatchJob.create!(
        sidekiq_batch_id: @batch.id,
        jid:              payload.fetch("jid"),
        worker_class:     payload.fetch("class"),
        args:             payload.fetch("args", []),
        status:           "pending"
      )
      @inserted_count += 1
    end

    private

    def in_open_transaction?
      ::ActiveRecord::Base.connection.open_transactions > self.class.transaction_baseline
    end
  end
end
