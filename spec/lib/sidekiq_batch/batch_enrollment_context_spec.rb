# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::BatchEnrollmentContext do
  let(:batch) { create(:sidekiq_batch) }

  describe "#run" do
    it "enrolls every job pushed inside the block" do
      batch.jobs do
        SidekiqBatchTestWorker.perform_async(1)
        SidekiqBatchTestWorker.perform_async(2, 3)
      end

      expect(batch.reload.status).to eq("running")
      expect(batch.total_jobs).to eq(2)
      expect(batch.sidekiq_batch_jobs.pluck(:worker_class, :args)).to contain_exactly(
        ["SidekiqBatchTestWorker", [1]],
        ["SidekiqBatchTestWorker", [2, 3]]
      )
    end

    it "matches enrolled jids to the jids Sidekiq assigned to the pushed jobs" do
      batch.jobs do
        SidekiqBatchTestWorker.perform_async
        SidekiqBatchTestWorker.perform_async
      end

      enrolled = batch.sidekiq_batch_jobs.pluck(:jid).sort
      pushed   = SidekiqBatchTestWorker.jobs.map { |j| j["jid"] }.sort

      expect(enrolled).to eq(pushed)
      expect(enrolled).to all(be_present)
    end

    it "enrolls bulk pushes (push_bulk / perform_bulk)" do
      batch.jobs do
        SidekiqBatchTestWorker.perform_bulk([[1], [2], [3]])
      end

      expect(batch.sidekiq_batch_jobs.count).to eq(3)
      expect(batch.total_jobs).to eq(3)
    end

    it "raises when the block is empty and destroys the orphan batch" do
      expect {
        batch.jobs {}
      }.to raise_error(described_class::EmptyEnrollmentError)

      expect(SidekiqBatch.exists?(batch.id)).to be(false)
    end

    it "raises when called inside a caller-opened transaction" do
      expect {
        ActiveRecord::Base.transaction do
          batch.jobs { SidekiqBatchTestWorker.perform_async }
        end
      }.to raise_error(described_class::TransactionError)
    end

    it "raises when a nested jobs {} block is attempted" do
      expect {
        batch.jobs do
          SidekiqBatchTestWorker.perform_async
          create(:sidekiq_batch).jobs { SidekiqBatchTestWorker.perform_async }
        end
      }.to raise_error(described_class::NestedError)
    end

    it "clears the thread-local context even on error" do
      expect {
        batch.jobs do
          SidekiqBatchTestWorker.perform_async
          raise "caller boom"
        end
      }.to raise_error("caller boom")

      expect(described_class.current).to be_nil
    end

    it "does not enroll perform_async calls made outside any jobs block" do
      SidekiqBatchTestWorker.perform_async(99)

      expect(SidekiqBatchJob.count).to eq(0)
    end

    it "fires the complete callback immediately when no work actually runs (fast-finish race)" do
      # Simulate the race: jobs already "finished" before the block closes by
      # marking every enrolled row complete from within the block. When the
      # block closes, attempt_completion! must fire the callback — otherwise
      # the batch is stuck (no future worker will trigger the check).
      batch.on(:complete, SidekiqBatchTestFanInJob)

      batch.jobs do
        SidekiqBatchTestWorker.perform_async
        SidekiqBatchJob.update_all(status: SidekiqBatchJob.statuses.fetch("complete"))
      end

      expect(batch.reload.status).to eq("complete")
      expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
    end
  end
end
