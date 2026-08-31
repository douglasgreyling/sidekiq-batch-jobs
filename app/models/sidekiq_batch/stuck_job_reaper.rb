# frozen_string_literal: true

class SidekiqBatch
  class StuckJobReaper
    Result = Struct.new(:batch, :jids, keyword_init: true)

    def self.call(live_jids: nil)
      new(live_jids).call
    end

    def initialize(live_jids = nil)
      @live_jids = live_jids
    end

    def call
      results = []

      stale_batches.find_each do |batch|
        result = reap_batch(batch)

        results << result if result
      end

      results
    end

    private

    def live_jids
      @live_jids ||= JidIndex.call
    end

    def stale_batches
      cutoff = Time.current - ::Sidekiq::Batch::Jobs.config.stuck_after

      SidekiqBatch.where(status: "running")
                  .where.not(id: SidekiqBatchJob.batch_ids_active_since(cutoff))
    end

    def reap_batch(batch)
      jids = reap(batch)

      batch.attempt_completion!

      jids.any? ? Result.new(batch: batch, jids: jids) : nil
    rescue StandardError => e
      ::Sidekiq::Batch::Jobs.config.alert(
        "SidekiqBatch ##{batch.id} could not be reaped (#{e.class}: #{e.message}). Skipped."
      )

      nil
    end

    def reap(batch)
      jids = []

      batch.pending_jobs.find_each do |batch_job|
        next if live_jids.include?(batch_job.jid)
        next unless batch_job.mark_failed!(OrphanedJobError.new(jid: batch_job.jid))

        jids << batch_job.jid
      end

      jids
    end
  end
end
