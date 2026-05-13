# frozen_string_literal: true

class SidekiqBatch
  # Sidekiq server middleware. Registered last in the chain so it runs
  # outside Sidekiq's retry middleware — we see the terminal disposition
  # of every attempt.
  #
  # - On success: mark complete, run completion check.
  # - On failure: only mark failed on the FINAL attempt (retries exhausted
  #   or retry: false). Non-terminal failures leave the row `pending` and
  #   skip the completion check; the next attempt will decide.
  # - Skips gracefully for jobs with no SidekiqBatchJob row (untracked).
  # - `mark_complete!` / `mark_failed!` are idempotent (atomic
  #   `WHERE status = 'pending'` update), so replays are no-ops.
  class Middleware
    DEFAULT_MAX_RETRIES = 25

    def call(worker, job, _queue) # rubocop:disable Metrics/MethodLength
      batch_job = ::SidekiqBatchJob.find_by(jid: job["jid"])

      unless batch_job
        yield

        return
      end

      begin
        yield
      rescue StandardError => e
        handle_failure(worker, job, batch_job, e)
        raise
      end

      handle_success(batch_job)
    end

    # Also used by the Sidekiq death handler to reconcile jobs that died
    # without re-entering middleware (SIGKILL, OOM, pod eviction, etc.).
    def self.handle_death(job, error)
      batch_job = ::SidekiqBatchJob.find_by(jid: job["jid"])

      return unless batch_job
      return unless batch_job.mark_failed!(error)

      batch_job.sidekiq_batch.attempt_completion!
    end

    private

    def handle_success(batch_job)
      return unless batch_job.mark_complete!

      batch_job.sidekiq_batch.attempt_completion!
    end

    def handle_failure(worker, job, batch_job, error)
      return unless final_attempt?(worker, job)
      return unless batch_job.mark_failed!(error)

      batch_job.sidekiq_batch.attempt_completion!
    end

    def final_attempt?(worker, job)
      retry_opt   = worker.class.get_sidekiq_options["retry"]
      max_retries = case retry_opt
                    when false, 0 then 0
                    when Integer then retry_opt
                    else DEFAULT_MAX_RETRIES
                    end

      retry_count = job["retry_count"] || 0

      retry_count >= max_retries
    end
  end
end
