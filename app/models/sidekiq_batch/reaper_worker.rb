# frozen_string_literal: true

class SidekiqBatch
  # Recovers batch state that silent failures leave inconsistent.
  class ReaperWorker
    include ::Sidekiq::Worker

    # The queue is read when this class is autoloaded, after initializers run,
    # so changing the setting later will not move an already-loaded worker; use
    # `set(queue:)` at push time. `retry: 3` rather than 25 because the next
    # scheduled run redoes the work, so a persistent failure should surface.
    sidekiq_options queue: ::Sidekiq::Batch::Jobs.config.maintenance_queue, retry: 3

    JID_PREVIEW = 5

    def perform
      jobs_config = ::Sidekiq::Batch::Jobs.config

      AbandonedEnrollmentReaper.call.each do |result|
        jobs_config.alert(abandoned_enrollment_message(result))
      end

      StuckJobReaper.call.each do |result|
        jobs_config.alert(stuck_jobs_message(result))
      end

      OrphanedCallbackReaper.call.each do |result|
        jobs_config.alert(orphaned_callback_message(result))
      end
    end

    private

    def abandoned_enrollment_message(result)
      "SidekiqBatch ##{result.batch.id} (#{describe(result.batch)}) never finished enrolling — " \
        "started it with the #{result.total_jobs} job(s) that were queued. Status is now " \
        "`#{result.batch.status}`."
    end

    def stuck_jobs_message(result)
      count   = result.jids.size
      preview = result.jids.first(JID_PREVIEW).join(", ")
      more    = count > JID_PREVIEW ? ", …(+#{count - JID_PREVIEW} more)" : ""

      "SidekiqBatch ##{result.batch.id} (#{describe(result.batch)}) had #{count} stuck job(s) " \
        "marked failed. Status is now `#{result.batch.status}`. JIDs: #{preview}#{more}."
    end

    def orphaned_callback_message(result)
      "SidekiqBatch ##{result.batch.id} (#{describe(result.batch)}) had an orphaned " \
        "`#{result.event}` callback re-fired (#{result.job_class}). Batch status: `#{result.batch.status}`."
    end

    def describe(batch)
      batch.description.presence || "(no description)"
    end
  end
end
