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
class SidekiqBatchJob < ActiveRecord::Base
  ERROR_MESSAGE_MAX = 4_000

  enum :status, { pending: 0, complete: 1, failed: 2 }, suffix: :status

  belongs_to :sidekiq_batch

  validates :jid, presence: true, uniqueness: true
  validates :worker_class, presence: true

  # Idempotent: returns true if the row was transitioned from `pending`
  # to `complete`; false if it was already terminal.
  def mark_complete!
    self.class.where(id: id, status: "pending").update_all(
      status:     self.class.statuses.fetch("complete"),
      updated_at: Time.current
    ).positive?
  end

  # Idempotent: returns true if the row was transitioned from `pending`
  # to `failed`; false if it was already terminal.
  def mark_failed!(error)
    self.class.where(id: id, status: "pending").update_all(
      status:        self.class.statuses.fetch("failed"),
      error_class:   error.class.name,
      error_message: error.message.to_s.truncate(ERROR_MESSAGE_MAX),
      updated_at:    Time.current
    ).positive?
  end
end
