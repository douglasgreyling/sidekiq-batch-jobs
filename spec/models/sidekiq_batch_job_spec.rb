# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatchJob, type: :model do
  subject { create(:sidekiq_batch_job, jid: SecureRandom.hex(12)) }

  it { is_expected.to belong_to(:sidekiq_batch) }
  it { is_expected.to validate_presence_of(:jid) }
  it { is_expected.to validate_presence_of(:worker_class) }
  it { is_expected.to validate_uniqueness_of(:jid) }

  describe "#mark_complete!" do
    let(:job) { create(:sidekiq_batch_job) }

    it "transitions pending → complete and returns true" do
      expect(job.mark_complete!).to eq(true)
      expect(job.reload.status).to eq("complete")
    end

    it "is idempotent — returns false when already terminal" do
      job.mark_complete!

      expect(job.mark_complete!).to eq(false)
    end

    it "does not flip a failed job to complete" do
      job.update!(status: "failed", error_class: "RuntimeError", error_message: "x")

      expect(job.mark_complete!).to eq(false)
      expect(job.reload.status).to eq("failed")
    end
  end

  describe "#mark_failed!" do
    let(:job)   { create(:sidekiq_batch_job) }
    let(:error) { RuntimeError.new("something went wrong") }

    it "transitions pending → failed and records error class + message" do
      expect(job.mark_failed!(error)).to eq(true)
      job.reload

      expect(job.status).to eq("failed")
      expect(job.error_class).to eq("RuntimeError")
      expect(job.error_message).to eq("something went wrong")
    end

    it "is idempotent — returns false when already terminal" do
      job.mark_failed!(error)

      expect(job.mark_failed!(error)).to eq(false)
    end

    it "truncates error_message to 4000 chars" do
      huge = RuntimeError.new("x" * 10_000)

      job.mark_failed!(huge)

      expect(job.reload.error_message.length).to eq(described_class::ERROR_MESSAGE_MAX)
    end
  end
end
