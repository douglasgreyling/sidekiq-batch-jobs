# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::Middleware do
  subject(:middleware) { described_class.new }

  let(:batch) { create(:sidekiq_batch, :with_callbacks) }
  let(:batch_job) do
    create(:sidekiq_batch_job, sidekiq_batch: batch, worker_class: "SidekiqBatchTestWorker")
  end

  def job_hash(jid: batch_job.jid, retry_count: nil)
    hash = { "jid" => jid, "class" => "SidekiqBatchTestWorker", "args" => [] }

    hash["retry_count"] = retry_count if retry_count

    hash
  end

  describe "#call" do
    context "for an untracked job (no SidekiqBatchJob row)" do
      it "yields and is a no-op" do
        yielded = false

        middleware.call(SidekiqBatchTestWorker.new, job_hash(jid: "untracked"), "default") { yielded = true }

        expect(yielded).to be(true)
      end
    end

    context "on success" do
      before { batch.update!(status: "running", total_jobs: 1) }

      it "marks the batch_job complete and runs the completion check" do
        middleware.call(SidekiqBatchTestWorker.new, job_hash, "default") { nil }

        expect(batch_job.reload.status).to eq("complete")
        expect(batch.reload.status).to eq("complete")
      end
    end

    context "on final-attempt failure (retry: false)" do
      before { batch.update!(status: "running", total_jobs: 1) }

      let(:worker) { SidekiqBatchBoomWorker.new }

      it "marks the batch_job failed and runs the completion check" do
        expect {
          middleware.call(worker, job_hash, "default") { raise "boom" }
        }.to raise_error("boom")

        expect(batch_job.reload.status).to eq("failed")
        expect(batch.reload.status).to eq("failed")
      end
    end

    context "on non-terminal failure (retries remaining)" do
      before { batch.update!(status: "running", total_jobs: 1) }

      let(:worker) { SidekiqBatchRetryingWorker.new }

      it "leaves the batch_job pending and does not transition the batch" do
        expect {
          middleware.call(worker, job_hash(retry_count: 0), "default") { raise "boom" }
        }.to raise_error("boom")

        expect(batch_job.reload.status).to eq("pending")
        expect(batch.reload.status).to eq("running")
      end

      it "marks failed only on the final allowed attempt" do
        # SidekiqBatchRetryingWorker has retry: 2 → retry_count 0,1 retry; 2 is final.
        expect {
          middleware.call(worker, job_hash(retry_count: 2), "default") { raise "boom" }
        }.to raise_error("boom")

        expect(batch_job.reload.status).to eq("failed")
      end
    end

    context "idempotency on replay" do
      before do
        batch.update!(status: "running", total_jobs: 1)
        batch_job.update_columns(status: "complete")
        batch.attempt_completion!
        SidekiqBatchTestFanInJob.clear
      end

      it "does not re-fire the callback when the job is re-run" do
        middleware.call(SidekiqBatchTestWorker.new, job_hash, "default") { nil }

        expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      end
    end
  end

  describe ".handle_death" do
    before { batch.update!(status: "running", total_jobs: 1) }

    it "marks the batch_job failed and fires the failure callback" do
      described_class.handle_death(job_hash, RuntimeError.new("killed"))

      expect(batch_job.reload.status).to eq("failed")
      expect(batch_job.reload.error_class).to eq("RuntimeError")
      expect(batch.reload.status).to eq("failed")
      expect(SidekiqBatchTestFailureJob.jobs.size).to eq(1)
    end

    it "is a no-op for untracked jobs" do
      expect {
        described_class.handle_death(job_hash(jid: "untracked"), RuntimeError.new("killed"))
      }.not_to change(SidekiqBatchJob, :count)
    end
  end
end
