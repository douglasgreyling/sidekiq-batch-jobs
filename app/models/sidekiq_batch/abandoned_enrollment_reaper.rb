# frozen_string_literal: true

class SidekiqBatch
  # Starts batches whose `jobs {}` block never got to finish.
  #
  # BatchEnrollmentContext handles an ordinary exception itself, but a SIGKILL
  # runs no rescue and leaves a `pending` batch whose jobs are already queued.
  # Nothing else looks at `pending`, so without this it never completes, never
  # announces, and never goes away. Adoption puts it back on the normal path
  # with `enrollment_error` set, so it finishes as a failure no tolerance can
  # excuse.
  class AbandonedEnrollmentReaper
    Result = Struct.new(:batch, :total_jobs, keyword_init: true)

    class << self
      def call
        results = []

        abandoned.find_each do |batch|
          result = adopt(batch)

          results << result if result
        end

        results
      end

      private

      # `created_at` older than the cutoff, or a batch with no rows yet would
      # trivially pass the staleness test and be adopted out from under its own
      # block. At least one enrollment row, because a batch that queued nothing
      # has nothing to announce and the groomer collects it instead. Then the same
      # "no recent job activity" test StuckJobReaper uses, which a block steadily
      # writing rows never trips.
      def abandoned
        cutoff = Time.current - ::Sidekiq::Batch::Jobs.config.stuck_after

        SidekiqBatch.where(status: "pending")
                    .where(created_at: ...cutoff)
                    .where(id: SidekiqBatchJob.select(:sidekiq_batch_id))
                    .where.not(id: SidekiqBatchJob.batch_ids_active_since(cutoff))
      end

      # Conditional on `pending`, like BatchEnrollmentContext#start!: the block
      # may be alive after all, and whichever of the two arrives second must do
      # nothing rather than overwrite the other's work.
      def adopt(batch)
        total = batch.sidekiq_batch_jobs.count

        return nil unless start(batch, total)

        batch.reload.attempt_completion!

        Result.new(batch: batch, total_jobs: total)
      rescue StandardError => e
        ::Sidekiq::Batch::Jobs.config.alert(
          "SidekiqBatch ##{batch.id} was abandoned mid-enrollment but could not be started " \
          "(#{e.class}: #{e.message}). Skipped."
        )

        nil
      end

      def start(batch, total)
        SidekiqBatch.where(id: batch.id, status: "pending").update_all(
          total_jobs:       total,
          status:           SidekiqBatch.statuses.fetch("running"),
          enrollment_error: { "class"   => AbandonedEnrollmentError.name,
                              "message" => AbandonedEnrollmentError.new.message },
          updated_at:       Time.current
        ).positive?
      end
    end
  end
end
