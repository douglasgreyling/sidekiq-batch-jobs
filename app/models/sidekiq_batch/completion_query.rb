# frozen_string_literal: true

class SidekiqBatch
  class CompletionQuery
    Policy = ::Sidekiq::Batch::Jobs::FailurePolicy

    class << self
      # @return [String] SQL with one `?` placeholder, for the batch id
      def sql
        <<~SQL.squish
          UPDATE sidekiq_batches
          SET status       = #{outcome},
              completed_at = NOW(),
              updated_at   = NOW()
          WHERE id = ?
            AND status = #{batch_status("running")}
            AND NOT EXISTS (#{jobs_with(job_status("pending"))})
          RETURNING status
        SQL
      end

      private

      def outcome
        <<~SQL
          CASE
            WHEN enrollment_error IS NOT NULL THEN #{batch_status("failed")}
            #{any_failure_branch}
            WHEN (#{failed_count}) > #{tolerated} THEN #{batch_status("failed")}
            ELSE #{batch_status("succeeded")}
          END
        SQL
      end

      # The default policy kept on its own cheap path. EXISTS stops at the first
      # failed row; COUNT would walk every one of them, and on a large failed
      # batch that is the difference between one index tuple and a hundred
      # thousand. A NULL policy lands here too, which is the safe reading of a
      # row written by something that bypassed the model.
      def any_failure_branch
        <<~SQL
          WHEN failure_policy IS NULL OR failure_policy = '#{Policy::ANY_FAILURE}'
            THEN CASE
                   WHEN EXISTS (#{jobs_with(job_status("failed"))}) THEN #{batch_status("failed")}
                   ELSE #{batch_status("succeeded")}
                 END
        SQL
      end

      def tolerated
        <<~SQL
          CASE failure_policy
            WHEN '#{Policy::ALL_FAILED}'       THEN GREATEST(total_jobs, 1) - 1
            WHEN '#{Policy::TOLERATE_JOBS}'    THEN #{tolerance}
            WHEN '#{Policy::TOLERATE_PERCENT}' THEN FLOOR(CAST(total_jobs AS numeric) * #{tolerance} / 100)
            ELSE 0
          END
        SQL
      end

      def tolerance
        "GREATEST(COALESCE(failure_tolerance, 0), 0)"
      end

      def failed_count
        "SELECT COUNT(*) FROM sidekiq_batch_jobs " \
          "WHERE sidekiq_batch_id = sidekiq_batches.id AND status = #{job_status("failed")}"
      end

      def jobs_with(status)
        "SELECT 1 FROM sidekiq_batch_jobs " \
          "WHERE sidekiq_batch_id = sidekiq_batches.id AND status = #{status}"
      end

      def batch_status(name)
        SidekiqBatch.statuses.fetch(name)
      end

      def job_status(name)
        SidekiqBatchJob.statuses.fetch(name)
      end
    end
  end
end
