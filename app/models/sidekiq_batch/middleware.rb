# frozen_string_literal: true

class SidekiqBatch
  class Middleware
    DEFAULT_MAX_RETRIES = 25

    def call(worker, job, _queue)
      batch_id = job[PAYLOAD_BATCH_ID_KEY]

      return yield unless batch_id

      begin
        yield
      rescue StandardError => e
        record_failure(worker, job, batch_id, e)
        raise
      end

      handle_success(job, batch_id)
    end

    # Also used by the Sidekiq death handler to reconcile jobs that died
    # without re-entering middleware (SIGKILL, OOM, pod eviction, etc.).
    def self.handle_death(job, error)
      batch_id = job[PAYLOAD_BATCH_ID_KEY]

      return unless batch_id
      return unless ::SidekiqBatchJob.fail!(job["jid"], error)

      check_completion(batch_id)
    end

    def self.check_completion(batch_id)
      ::SidekiqBatch.attempt_completion!(batch_id)
    rescue StandardError => e
      ::Sidekiq::Batch::Jobs.config.alert(
        "SidekiqBatch ##{batch_id}: completion check failed after a job reached a " \
        "terminal state (#{e.class}: #{e.message}). The reaper will pick it up."
      )

      nil
    end

    private

    def handle_success(job, batch_id)
      return unless ::SidekiqBatchJob.complete!(job["jid"])

      self.class.check_completion(batch_id)
    end

    # The job's own exception has to be the one that leaves this method: Sidekiq
    # reports it, `sidekiq_retry_in` is handed it, and it is what says why the
    # job died. A failed bookkeeping write taking its place would name the
    # database instead of the bug. The row is recoverable either way, by the
    # death handler on the final attempt or by the reaper after that.
    def record_failure(worker, job, batch_id, error)
      handle_failure(worker, job, batch_id, error)
    rescue StandardError => e
      ::Sidekiq::Batch::Jobs.config.alert(
        "SidekiqBatch ##{batch_id}: could not record the failure of job #{job["jid"]} " \
        "(#{e.class}: #{e.message}). The reaper will pick it up."
      )

      nil
    end

    def handle_failure(worker, job, batch_id, error)
      return unless final_attempt?(worker, job)
      return unless ::SidekiqBatchJob.fail!(job["jid"], error)

      self.class.check_completion(batch_id)
    end

    def final_attempt?(worker, job)
      max_retries = max_retries_for(worker, job)

      return true if max_retries.zero?

      retry_count = job["retry_count"]

      retry_count.is_a?(Integer) && retry_count >= max_retries - 1
    end

    def max_retries_for(worker, job)
      retry_opt = job["retry"]
      retry_opt = worker.class.get_sidekiq_options["retry"] if retry_opt.nil?

      case retry_opt
      when false, 0 then 0
      when Integer  then retry_opt
      else ::Sidekiq.default_configuration[:max_retries] || DEFAULT_MAX_RETRIES
      end
    end
  end
end
