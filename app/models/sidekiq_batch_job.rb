# frozen_string_literal: true

# == Schema Information
#
# Table name: sidekiq_batch_jobs
#
#  id               :bigint           not null, primary key
#  args             :jsonb            not null
#  error_class      :string
#  error_message    :text
#  jid              :string           not null
#  status           :integer          default("pending"), not null
#  worker_class     :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  sidekiq_batch_id :bigint           not null
#
class SidekiqBatchJob < ::Sidekiq::Batch::Jobs.base_class
  # Positional, with `suffix:`, because ActiveRecord 8 accepts no other form.
  enum :status, { pending: 0, complete: 1, failed: 2 }, suffix: :status

  belongs_to :sidekiq_batch

  # jid uniqueness is left to the unique index. The validation's SELECT was
  # never a guarantee — two enrolling threads can both pass it and race to the
  # INSERT — and it cost a query on every enrolled job.
  validates :jid, presence: true
  validates :worker_class, presence: true

  class << self
    def complete!(jid)
      transition(jid, "complete")
    end

    def fail!(jid, error)
      transition(jid, "failed", error_attributes(error))
    end

    def batch_ids_active_since(cutoff)
      where(updated_at: cutoff..).select(:sidekiq_batch_id)
    end

    private

    def transition(jid, to, extra = {})
      where(jid: jid, status: "pending").update_all(
        { status: statuses.fetch(to), updated_at: Time.current }.merge(extra)
      ).positive?
    end

    def error_attributes(error)
      {
        error_class:   error.class.name,
        error_message: error.message.to_s.truncate(::Sidekiq::Batch::Jobs.config.error_message_max)
      }
    end
  end

  def mark_complete!
    self.class.complete!(jid)
  end

  def mark_failed!(error)
    self.class.fail!(jid, error)
  end
end
