# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::Middleware do
  subject(:middleware) { described_class.new }

  let(:batch) { create(:sidekiq_batch, :with_callbacks) }
  let(:batch_job) do
    create(:sidekiq_batch_job, sidekiq_batch: batch, worker_class: "SidekiqBatchTestWorker")
  end

  # Mirrors what the client middleware pushes: a tracked job carries the batch
  # id, an untracked one has no such key. Pass `batch_id: nil` for the latter.
  #
  # `retry_option` stands in for a `set(retry:)` override, which Sidekiq
  # normalizes into the payload. :unset leaves the key out entirely, so `false`
  # and `nil` can both be passed deliberately.
  def job_hash(jid: batch_job.jid, retry_count: nil, retry_option: :unset, batch_id: batch.id)
    hash = { "jid" => jid, "class" => "SidekiqBatchTestWorker", "args" => [] }

    hash[SidekiqBatch::PAYLOAD_BATCH_ID_KEY] = batch_id if batch_id
    hash["retry_count"]                      = retry_count if retry_count
    hash["retry"]                            = retry_option unless retry_option == :unset

    hash
  end

  describe "#call" do
    context "for an untracked job (no batch id in the payload)" do
      it "yields and is a no-op" do
        yielded = false

        middleware.call(SidekiqBatchTestWorker.new, job_hash(batch_id: nil), "default") { yielded = true }

        expect(yielded).to be(true)
      end

      it "touches the database zero times" do
        # This chain wraps every job in the host application. An untracked job
        # must not pay a lookup to be told it is untracked, and must not be
        # coupled to Postgres being reachable to run at all. Build the payload
        # outside the counter so the factories' own queries are not counted.
        payload = job_hash(batch_id: nil)

        queries = count_queries do
          middleware.call(SidekiqBatchTestWorker.new, payload, "default") { nil }
        end

        expect(queries).to eq(0)
      end
    end

    context "for a payload carrying a batch id with no matching row" do
      it "yields and leaves the batch alone" do
        yielded = false

        middleware.call(SidekiqBatchTestWorker.new, job_hash(jid: "untracked"), "default") { yielded = true }

        expect(yielded).to be(true)
        expect(batch.reload.status).to eq("pending")
      end
    end

    context "query cost on the tracked path" do
      before { batch.update!(status: "running", total_jobs: 2) }

      it "loads neither the job row nor the batch when the batch is not yet done" do
        create(:sidekiq_batch_job, sidekiq_batch: batch, worker_class: "SidekiqBatchTestWorker")
        payload = job_hash

        queries = queries_made do
          middleware.call(SidekiqBatchTestWorker.new, payload, "default") { nil }
        end

        # One UPDATE marking the row complete, one for the completion check that
        # matches nothing. Every job that is not the last one takes this path, so
        # neither the row nor the batch is worth a SELECT. The grep is anchored
        # because that completion UPDATE contains `SELECT 1` guard subqueries.
        expect(queries.grep(/\ASELECT/)).to be_empty
        expect(queries.size).to eq(2)
      end
    end

    context "on success" do
      before { batch.update!(status: "running", total_jobs: 1) }

      it "marks the batch_job complete and runs the completion check" do
        middleware.call(SidekiqBatchTestWorker.new, job_hash, "default") { nil }

        expect(batch_job.reload.status).to eq("complete")
        expect(batch.reload.status).to eq("succeeded")
      end
    end

    context "on final-attempt failure (retry: false)" do
      before { batch.update!(status: "running", total_jobs: 1) }

      let(:worker) { SidekiqBatchBoomWorker.new }

      it "marks the batch_job failed and runs the completion check" do
        expect do
          middleware.call(worker, job_hash, "default") { raise "boom" }
        end.to raise_error("boom")

        expect(batch_job.reload.status).to eq("failed")
        expect(batch.reload.status).to eq("failed")
      end
    end

    context "on non-terminal failure (retries remaining)" do
      before { batch.update!(status: "running", total_jobs: 1) }

      let(:worker) { SidekiqBatchRetryingWorker.new }

      it "leaves the batch_job pending and does not transition the batch" do
        expect do
          middleware.call(worker, job_hash(retry_count: 0), "default") { raise "boom" }
        end.to raise_error("boom")

        expect(batch_job.reload.status).to eq("pending")
        expect(batch.reload.status).to eq("running")
      end

      it "marks failed only on the final allowed attempt" do
        # SidekiqBatchRetryingWorker has retry: 2, so Sidekiq allows three
        # executions and stamps them nil, 0, 1. The final one carries 1 —
        # retry_count never reaches 2, which is why `>= max_retries` never
        # fired for any retrying worker.
        expect do
          middleware.call(worker, job_hash(retry_count: 1), "default") { raise "boom" }
        end.to raise_error("boom")

        expect(batch_job.reload.status).to eq("failed")
        expect(batch.reload.status).to eq("failed")
      end

      it "treats a missing retry_count as the first execution, not the final one" do
        # retry: 1 allows two executions, stamped nil then 0. Coercing the nil
        # to 0 would make the first attempt look final and fail the row before
        # Sidekiq has retried even once.
        expect do
          middleware.call(SidekiqBatchTestWorker.new, job_hash(retry_option: 1), "default") { raise "boom" }
        end.to raise_error("boom")

        expect(batch_job.reload.status).to eq("pending")
        expect(batch.reload.status).to eq("running")
      end
    end

    context "when a set(retry:) override disagrees with the class option" do
      before { batch.update!(status: "running", total_jobs: 1) }

      # SidekiqBatchBoomWorker declares retry: false, but the payload carries 5.
      # Sidekiq's JobRetry reads the payload, so the job WILL be retried —
      # marking the row failed here is unrecoverable, since mark_complete!
      # only ever transitions out of `pending`.
      let(:worker) { SidekiqBatchBoomWorker.new }

      it "defers to the payload and leaves the row pending while retries remain" do
        expect do
          middleware.call(worker, job_hash(retry_option: 5, retry_count: 0), "default") { raise "boom" }
        end.to raise_error("boom")

        expect(batch_job.reload.status).to eq("pending")
        expect(batch.reload.status).to eq("running")
      end

      it "marks failed on the final attempt the payload allows" do
        expect do
          middleware.call(worker, job_hash(retry_option: 5, retry_count: 4), "default") { raise "boom" }
        end.to raise_error("boom")

        expect(batch_job.reload.status).to eq("failed")
      end

      it "still honours the class option when the payload has no retry key" do
        expect do
          middleware.call(worker, job_hash, "default") { raise "boom" }
        end.to raise_error("boom")

        expect(batch_job.reload.status).to eq("failed")
      end
    end

    # A retry cannot repair the completion check: `complete!` returns false the
    # second time and the check is never reached again. Re-raising would only
    # re-run the user's job — running its side effects twice because of a
    # bookkeeping query.
    context "when the completion check fails after the job succeeded" do
      before do
        batch.update!(status: "running", total_jobs: 1)
        allow(SidekiqBatch).to receive(:attempt_completion!).and_raise("postgres went away")
      end

      it "lets the job stand rather than re-running it" do
        expect { middleware.call(SidekiqBatchTestWorker.new, job_hash, "default") { nil } }
          .not_to raise_error

        expect(batch_job.reload.status).to eq("complete")
      end

      it "alerts so the batch is known to need the reaper" do
        alerts                                          = []
        Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(message) { alerts << message } }

        middleware.call(SidekiqBatchTestWorker.new, job_hash, "default") { nil }

        expect(alerts.join).to include("##{batch.id}", "postgres went away")
      end

      # On the failure path the original exception is what Sidekiq must see —
      # a bookkeeping error masking it would misreport why the job died.
      it "does not mask the job's own error on the failure path" do
        expect do
          middleware.call(SidekiqBatchBoomWorker.new, job_hash, "default") { raise "the real failure" }
        end.to raise_error("the real failure")
      end
    end

    # The write itself, one step earlier than the completion check above. Its
    # likeliest trigger is not an outage but an error message Postgres refuses,
    # a null byte from an upstream API say, which fails for that one job every
    # time it is attempted.
    context "when the failure cannot be written down" do
      before do
        batch.update!(status: "running", total_jobs: 1)
        allow(SidekiqBatchJob).to receive(:fail!).and_raise(ActiveRecord::StatementInvalid, "pg gone")
      end

      it "still reports the job's own error, not the write's" do
        expect do
          middleware.call(SidekiqBatchBoomWorker.new, job_hash, "default") { raise "the real failure" }
        end.to raise_error("the real failure")
      end

      it "alerts, so the row is known to need the reaper" do
        alerts                                          = []
        Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(message) { alerts << message } }

        expect do
          middleware.call(SidekiqBatchBoomWorker.new, job_hash, "default") { raise "the real failure" }
        end.to raise_error("the real failure")

        expect(alerts.join).to include("##{batch.id}", batch_job.jid, "pg gone")
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
      expect do
        described_class.handle_death(job_hash(jid: "untracked"), RuntimeError.new("killed"))
      end.not_to change(SidekiqBatchJob, :count)
    end

    it "touches the database zero times for a payload with no batch id" do
      payload = job_hash(batch_id: nil)

      queries = count_queries { described_class.handle_death(payload, RuntimeError.new("killed")) }

      expect(queries).to eq(0)
      expect(batch_job.reload.status).to eq("pending")
    end
  end
end
