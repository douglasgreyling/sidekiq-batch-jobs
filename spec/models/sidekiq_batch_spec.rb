# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch, type: :model do
  subject { build(:sidekiq_batch) }

  it { is_expected.to have_many(:sidekiq_batch_jobs).dependent(:destroy) }

  describe "status enum" do
    it "rejects an unknown status at assignment time" do
      expect { described_class.new(status: "bogus") }.to raise_error(ArgumentError)
    end
  end

  describe "#on" do
    let(:batch) { create(:sidekiq_batch) }

    it "persists the callback class name as a string" do
      batch.on(:complete, SidekiqBatchTestFanInJob)

      expect(batch.reload.callbacks).to eq("complete" => "SidekiqBatchTestFanInJob")
    end

    it "accepts a string job class" do
      batch.on("failure", "SidekiqBatchTestFailureJob")

      expect(batch.reload.callbacks).to eq("failure" => "SidekiqBatchTestFailureJob")
    end

    it "raises for unknown events" do
      expect { batch.on(:wat, "X") }.to raise_error(ArgumentError, /unknown event/)
    end
  end

  describe "#progress" do
    let(:batch) { create(:sidekiq_batch, :running, total_jobs: 3) }

    before do
      create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
      create(:sidekiq_batch_job, :failed,   sidekiq_batch: batch)
      create(:sidekiq_batch_job,            sidekiq_batch: batch)
    end

    it "returns counts by status plus total" do
      expect(batch.progress).to eq(total: 3, complete: 1, failed: 1, pending: 1)
    end
  end

  describe "#attempt_completion!" do
    let(:batch) { create(:sidekiq_batch, :running, total_jobs: 2) }

    before do
      batch.on(:complete, SidekiqBatchTestFanInJob)
      batch.on(:failure, SidekiqBatchTestFailureJob)
    end

    context "when pending jobs remain" do
      before do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job,            sidekiq_batch: batch)
      end

      it "returns nil and does not transition" do
        expect(batch.attempt_completion!).to be_nil
        expect(batch.reload.status).to eq("running")
      end
    end

    context "when all jobs are complete" do
      before do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
      end

      it "transitions to complete and fires the complete callback" do
        expect(batch.attempt_completion!).to eq("complete")
        batch.reload

        expect(batch.status).to eq("complete")
        expect(batch.completed_at).to be_present
        expect(batch.callback_fired_at).to be_present
        expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestFanInJob.jobs.first["args"]).to eq([batch.id])
      end
    end

    context "when at least one job failed" do
      before do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job, :failed,   sidekiq_batch: batch)
      end

      it "transitions to failed and fires the failure callback" do
        expect(batch.attempt_completion!).to eq("failed")

        expect(batch.reload.status).to eq("failed")
        expect(SidekiqBatchTestFailureJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      end
    end

    context "when already terminal" do
      before do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        batch.attempt_completion!
        SidekiqBatchTestFanInJob.clear
      end

      it "returns nil on a second call and does not re-fire the callback" do
        expect(batch.attempt_completion!).to be_nil
        expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      end
    end

    context "with no callback registered for the event" do
      let(:batch) { create(:sidekiq_batch, :running, total_jobs: 1) }

      before do
        batch.update!(callbacks: {})
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
      end

      it "still transitions status but fires nothing" do
        expect(batch.attempt_completion!).to eq("complete")
        expect(batch.reload.callback_fired_at).to be_nil
      end
    end
  end

  describe "#fire_callback" do
    let(:batch) { create(:sidekiq_batch, :with_callbacks) }

    it "is a no-op if called a second time on the same batch" do
      batch.fire_callback(:complete)
      first_fired_at = batch.reload.callback_fired_at
      SidekiqBatchTestFanInJob.clear

      expect(batch.fire_callback(:complete)).to be_nil
      expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      expect(batch.reload.callback_fired_at).to eq(first_fired_at)
    end
  end
end
