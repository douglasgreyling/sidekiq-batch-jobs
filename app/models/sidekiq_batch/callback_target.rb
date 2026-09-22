# frozen_string_literal: true

class SidekiqBatch
  # Turns a registered callback class into an enqueued job.
  #
  # Two shapes are accepted, told apart by the enqueue method each answers to:
  # including `Sidekiq::Job` defines `perform_async` and never `perform_later`,
  # while `ActiveJob::Base` defines exactly the reverse. Nothing here inspects
  # ancestors, so a class that provides either interface some other way works
  # too.
  module CallbackTarget
    class << self
      # Whether {.enqueue} could send this class. Used by `SidekiqBatch#on` so a
      # class that can never be delivered is rejected where it is registered.
      def supported?(job_class)
        sidekiq_job?(job_class) || active_job?(job_class)
      end

      # Runs inside the transaction that claims the event, which is the whole
      # constraint on this method: neither branch may defer its push past that
      # commit. See {.push_active_job}.
      def enqueue(job_class, batch_id)
        return job_class.perform_async(batch_id) if sidekiq_job?(job_class)

        push_active_job(job_class, batch_id)
      end

      # Registration is where an undeliverable callback is cheap to catch. Left
      # to the announcement it costs a great deal more: the push raises, the
      # claim rolls back, `fire` swallows it into an alert, and the unclaimed
      # event keeps the batch in the orphaned-callback scope, alerting again on
      # every reaper run until grooming deletes it.
      def validate!(job_class)
        klass = job_class.is_a?(Module) ? job_class : job_class.to_s.safe_constantize

        # A name that does not resolve here is left alone rather than guessed
        # at: in a Rails application it may simply not be autoloaded yet, and
        # the announcement resolves it again when it fires.
        return if klass.nil?
        return if supported?(klass)

        raise ArgumentError, unsupported_message(klass)
      end

      def unsupported_message(job_class)
        if job_class.respond_to?(:perform_later)
          "#{job_class} is an ActiveJob class, but Sidekiq's ActiveJob adapter is not loaded, " \
            "so there is no wrapper to enqueue it through. Set " \
            "`config.active_job.queue_adapter = :sidekiq`, or register a class that includes " \
            "`Sidekiq::Job` instead."
        else
          "#{job_class} cannot be a batch callback: it answers to neither `perform_async` " \
            "(from `Sidekiq::Job`) nor `perform_later` (from `ActiveJob::Base`), so there is no " \
            "way to enqueue it. Callbacks are enqueued by this gem, not called inline."
        end
      end

      private

      def sidekiq_job?(job_class)
        job_class.respond_to?(:perform_async)
      end

      # The adapter is what supplies the wrapper the payload is pushed as, so
      # without it an ActiveJob cannot be delivered through Sidekiq at all.
      def active_job?(job_class)
        job_class.respond_to?(:perform_later) && defined?(::Sidekiq::ActiveJob::Wrapper)
      end

      # Deliberately not `perform_later`.
      #
      # Sidekiq's ActiveJob adapter declares `enqueue_after_transaction_commit?`,
      # so `perform_later` hands the push to an after-commit hook rather than
      # running it here. The claim would then commit first, and a crash in that
      # window leaves the event claimed with nothing sent. Nothing recovers
      # that: a spent claim is exactly what stops the orphaned-callback reaper
      # looking at the batch again. Pushing the wrapper payload ourselves keeps
      # the enqueue inside the claim transaction, where the existing guarantee
      # holds, which is that a rollback un-claims the event and the reaper
      # retries it.
      #
      # The payload is the one the adapter builds. The cost of not going through
      # ActiveJob is that its enqueue callbacks (`before_enqueue` and friends)
      # do not run.
      def push_active_job(job_class, batch_id)
        job = job_class.new(batch_id)

        ::Sidekiq::Client.push(
          "class"   => ::Sidekiq::ActiveJob::Wrapper,
          "wrapped" => job_class,
          "queue"   => job.queue_name,
          "args"    => [job.serialize]
        )
      end
    end
  end
end
