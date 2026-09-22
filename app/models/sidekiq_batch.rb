# frozen_string_literal: true

# == Schema Information
#
# Table name: sidekiq_batches
#
#  id                :bigint           not null, primary key
#  callback_fired_at :datetime
#  callbacks         :jsonb            not null
#  callbacks_fired   :jsonb            not null
#  complete_count    :integer
#  completed_at      :datetime
#  context           :jsonb            not null
#  description       :string
#  enrollment_error  :jsonb
#  failed_count      :integer
#  failure_policy    :string
#  failure_tolerance :integer
#  status            :integer          default("pending"), not null
#  total_jobs        :integer          default(0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
class SidekiqBatch < ::Sidekiq::Batch::Jobs.base_class
  # `complete` fires whatever the outcome; `success` and `failure` name it.
  # Three rather than two, so "always do X, and separately alert on failure"
  # needs no duplicate registration. Same vocabulary as Sidekiq Pro.
  EVENTS = %w[complete success failure].freeze

  PAYLOAD_BATCH_ID_KEY = "sidekiq_batch_id"

  # `succeeded`, not `complete`: `:complete` is the event that fires whatever
  # the outcome, so a status of that name would mean the opposite of the event
  # firing beside it.
  #
  # Positional, with `suffix:`, because ActiveRecord 8 accepts no other form.
  # The suffix is what keeps `failed_status?` clear of the `failure` callback
  # vocabulary sitting beside it.
  enum :status, { pending: 0, running: 1, succeeded: 2, failed: 3 }, suffix: :status

  has_many :sidekiq_batch_jobs, dependent: :delete_all

  before_validation :apply_default_failure_policy, on: :create

  validates :total_jobs, numericality: { greater_than_or_equal_to: 0 }
  validates :failure_policy,
            inclusion: { in: ::Sidekiq::Batch::Jobs::FailurePolicy::NAMES, allow_nil: true }
  validate  :failure_tolerance_suits_policy

  class << self
    # By id, without loading the batch first. Nearly every call comes from a
    # job that is not the last one, and those cost one UPDATE that matches
    # nothing; the row is fetched only once the UPDATE has transitioned it.
    #
    # @return [String, nil] resulting status, or nil when not ready yet.
    def attempt_completion!(batch_id)
      result = connection.exec_query(sanitize_sql_array([CompletionQuery.sql, batch_id]))

      return nil if result.rows.empty?

      batch = find(batch_id)

      batch.fire_callbacks

      batch.status
    end
  end

  # Accepts every form FailurePolicy does. Two columns back one value, because
  # the completion statement has to read both without parsing JSON. Assigning
  # either column directly skips this, so validation catches a mismatched pair.
  def failure_policy=(value)
    if value.nil?
      super
      self.failure_tolerance = nil

      return
    end

    policy = ::Sidekiq::Batch::Jobs::FailurePolicy.normalize(value)

    super(policy.name)
    self.failure_tolerance = policy.tolerance
  end

  def on(event, job_class)
    event_str = event.to_s
    raise ArgumentError, "unknown event #{event.inspect}" unless EVENTS.include?(event_str)

    if terminal?
      raise ArgumentError,
            "cannot register a #{event_str} callback on a batch that has already finished (#{status})"
    end

    CallbackTarget.validate!(job_class)

    self.callbacks = callbacks.merge(event_str => job_class.to_s)

    save!

    self
  end

  def terminal?
    succeeded_status? || failed_status?
  end

  def jobs(&block)
    raise ArgumentError, "block required" unless block_given?

    BatchEnrollmentContext.new(self).run(&block)

    self
  end

  # Percentage of {#total_jobs} in a terminal state, rounded to two decimal
  # places. Failed jobs count as finished. 0.0 when there are no jobs.
  def percentage_progress
    return 0.0 if total_jobs.zero?

    return 100.0 if terminal?

    ((finished_jobs_count.to_f / total_jobs) * 100).round(2)
  end

  # Time until the batch finishes, extrapolated from the throughput observed
  # since it was created. nil when no estimate is possible, zero once every
  # job is terminal.
  def eta
    return nil unless running_status?
    return nil if total_jobs.zero?

    finished = finished_jobs_count

    return nil                              if finished.zero?
    return ActiveSupport::Duration.build(0) if finished >= total_jobs

    ActiveSupport::Duration.build(seconds_remaining(finished).round)
  end

  def progress
    stamped_counts || count_by_status
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

  def attempt_completion!
    result = self.class.attempt_completion!(id)

    # The transition happened in raw SQL against a different instance, and
    # callers like StuckJobReaper read status off the object they passed in.
    reload if result

    result
  end

  # Enqueues the callbacks this batch's outcome calls for, each at most once:
  # `complete` either way, plus `success` or `failure`. Nothing on an
  # unfinished batch. See Announcement for the claim mechanics.
  #
  # @return [Array<Announcement::Fired>] one entry per callback enqueued
  def fire_callbacks
    Announcement.call(self)
  end

  private

  def apply_default_failure_policy
    return unless failure_policy.nil?

    self.failure_policy = ::Sidekiq::Batch::Jobs.config.failure_policy
  end

  def failure_tolerance_suits_policy
    tolerated = [::Sidekiq::Batch::Jobs::FailurePolicy::TOLERATE_JOBS,
                 ::Sidekiq::Batch::Jobs::FailurePolicy::TOLERATE_PERCENT].include?(failure_policy)

    if tolerated
      errors.add(:failure_tolerance, "is required for a #{failure_policy} policy") if failure_tolerance.nil?
      errors.add(:failure_tolerance, "cannot be negative") if failure_tolerance&.negative?
    elsif failure_tolerance.present?
      errors.add(:failure_tolerance, "only applies to a tolerating policy")
    end
  end

  def stamped_counts
    return nil unless terminal? && complete_count && failed_count

    { total: total_jobs, complete: complete_count, failed: failed_count, pending: 0 }
  end

  def count_by_status
    counts = sidekiq_batch_jobs.group(:status).count

    {
      total:    total_jobs,
      complete: counts.fetch("complete", 0),
      failed:   counts.fetch("failed", 0),
      pending:  counts.fetch("pending", 0)
    }
  end

  def finished_jobs_count
    sidekiq_batch_jobs.where(status: %w[complete failed]).count
  end

  def seconds_remaining(finished)
    elapsed = Time.current - created_at
    rate    = finished.to_f / elapsed

    (total_jobs - finished) / rate
  end
end
