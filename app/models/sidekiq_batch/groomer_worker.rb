# frozen_string_literal: true

class SidekiqBatch
  class GroomerWorker
    include ::Sidekiq::Worker

    # See ReaperWorker for both: the queue is fixed at autoload time, and
    # idempotent cron work should surface a failure rather than retry 25 times.
    sidekiq_options queue: ::Sidekiq::Batch::Jobs.config.maintenance_queue, retry: 3

    def perform
      RecordGroomer.call
    end
  end
end
