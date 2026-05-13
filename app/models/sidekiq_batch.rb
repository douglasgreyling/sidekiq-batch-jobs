# frozen_string_literal: true

# == Schema Information
#
# Table name: sidekiq_batches
#
#  id                :bigint           not null, primary key
#  callback_fired_at :datetime
#  callbacks         :jsonb            not null
#  completed_at      :datetime
#  context           :jsonb            not null
#  description       :string
#  status            :integer          default("pending"), not null
#  total_jobs        :integer          default(0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
class SidekiqBatch < ActiveRecord::Base
  EVENTS = %w[complete failure].freeze

  enum :status, { pending: 0, running: 1, complete: 2, failed: 3 }, suffix: :status

  has_many :sidekiq_batch_jobs, dependent: :destroy

  validates :total_jobs, numericality: { greater_than_or_equal_to: 0 }

  def on(event, job_class)
    event_str = event.to_s
    raise ArgumentError, "unknown event #{event.inspect}" unless EVENTS.include?(event_str)

    self.callbacks = callbacks.merge(event_str => job_class.to_s)

    save!

    self
  end

  def jobs(&block)
    raise ArgumentError, "block required" unless block_given?

    BatchEnrollmentContext.new(self).run(&block)

    self
  end

  def progress
    counts = sidekiq_batch_jobs.group(:status).count

    {
      total:    total_jobs,
      complete: counts.fetch("complete", 0),
      failed:   counts.fetch("failed", 0),
      pending:  counts.fetch("pending", 0)
    }
  end

  def pending_jobs
    sidekiq_batch_jobs.where(status: "pending")
  end

  def failed_jobs
    sidekiq_batch_jobs.where(status: "failed")
  end

  def completed_jobs
    sidekiq_batch_jobs.where(status: "complete")
  end

  # Atomic completion check. If all enrolled jobs are terminal, transition the
  # batch to `complete` or `failed`, fire the registered callback, and stamp
  # `callback_fired_at`. Returns the resulting status (String) or nil if the
  # batch is not yet ready to transition.
  def attempt_completion!
    sql = self.class.sanitize_sql_array([completion_sql, id])

    result = self.class.connection.exec_query(sql)

    return nil if result.rows.empty?

    reload

    event = failed_status? ? "failure" : "complete"

    fire_callback(event)

    status
  end

  def fire_callback(event)
    return nil if callback_fired_at.present?

    job_class_name = callbacks[event.to_s]

    return nil if job_class_name.blank?

    self.class.transaction do
      update!(callback_fired_at: Time.current)
      job_class_name.constantize.perform_async(id)
    end

    job_class_name
  end

  private

  def completion_sql # rubocop:disable Metrics/MethodLength
    batch_statuses = self.class.statuses
    job_statuses   = SidekiqBatchJob.statuses

    <<~SQL.squish
      UPDATE sidekiq_batches
      SET
        status = CASE
          WHEN EXISTS (
            SELECT 1 FROM sidekiq_batch_jobs
            WHERE sidekiq_batch_id = sidekiq_batches.id
              AND status = #{job_statuses.fetch("failed")}
          ) THEN #{batch_statuses.fetch("failed")}
          ELSE #{batch_statuses.fetch("complete")}
        END,
        completed_at = NOW(),
        updated_at   = NOW()
      WHERE id = ?
        AND status = #{batch_statuses.fetch("running")}
        AND NOT EXISTS (
          SELECT 1 FROM sidekiq_batch_jobs
          WHERE sidekiq_batch_id = sidekiq_batches.id
            AND status = #{job_statuses.fetch("pending")}
        )
      RETURNING status
    SQL
  end
end
