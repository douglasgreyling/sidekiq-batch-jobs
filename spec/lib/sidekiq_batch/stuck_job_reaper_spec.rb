# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::StuckJobReaper do
  # Everything here turns on age: the reaper only looks at batches whose jobs
  # have been untouched for longer than config.stuck_after (2h by default), so
  # every fixture is created in the past.
  def stale_batch(job_count: 1)
    travel_to(3.hours.ago) do
      batch = create(:sidekiq_batch, :running, total_jobs: job_count)
      create_list(:sidekiq_batch_job, job_count, sidekiq_batch: batch)
      batch
    end
  end

  describe "a pending job whose jid is gone from Sidekiq" do
    let!(:batch) { stale_batch }
    let(:job)    { batch.sidekiq_batch_jobs.first }

    it "marks the row failed and records why" do
      described_class.call(live_jids: Set.new)

      job.reload

      expect(job).to be_failed_status
      expect(job.error_class).to eq("SidekiqBatch::OrphanedJobError")
      expect(job.error_message).to match(/orphaned by the stuck-job reaper/)
    end

    it "lets the batch reach a terminal state" do
      described_class.call(live_jids: Set.new)

      expect(batch.reload).to be_failed_status
    end

    it "reports the batch and the jids it reaped" do
      results = described_class.call(live_jids: Set.new)

      expect(results.map(&:batch)).to eq([batch])
      expect(results.first.jids).to eq([job.jid])
    end
  end

  describe "a pending job Sidekiq still knows about" do
    let!(:batch) { stale_batch }

    it "is left alone" do
      job = batch.sidekiq_batch_jobs.first

      results = described_class.call(live_jids: Set[job.jid])

      expect(job.reload).to be_pending_status
      expect(batch.reload).to be_running_status
      expect(results).to be_empty
    end
  end

  describe "a batch with recent job activity" do
    it "is skipped even when its jids are gone, so we never race Sidekiq's own recovery" do
      batch = create(:sidekiq_batch, :running, total_jobs: 1)
      job   = create(:sidekiq_batch_job, sidekiq_batch: batch)

      results = described_class.call(live_jids: Set.new)

      expect(job.reload).to be_pending_status
      expect(results).to be_empty
    end
  end

  describe "a batch that is already terminal" do
    it "is not considered, since only running batches can be stuck" do
      batch = travel_to(3.hours.ago) { create(:sidekiq_batch, :with_all_jobs_complete) }
      batch.update!(status: "succeeded")

      expect(described_class.call(live_jids: Set.new)).to be_empty
    end
  end

  describe "the jid index when one is not supplied" do
    before { allow(SidekiqBatch::JidIndex).to receive(:call).and_return(Set.new) }

    it "is built when there is stale work to check against" do
      stale_batch

      described_class.call

      expect(SidekiqBatch::JidIndex).to have_received(:call)
    end

    # Enumerating every queue and sorted set in Redis is the most expensive
    # thing the gem does, and the healthy steady state has nothing stale to
    # check against — so the scheduled reaper should not be paying for it.
    it "is not built at all when nothing is stale" do
      create(:sidekiq_batch, :running, total_jobs: 1)

      expect(described_class.call).to be_empty
      expect(SidekiqBatch::JidIndex).not_to have_received(:call)
    end

    it "is built only once across many stale batches" do
      3.times { stale_batch }

      described_class.call

      expect(SidekiqBatch::JidIndex).to have_received(:call).once
    end
  end

  # One unhealthy batch must not strand every other stalled batch in the system.
  describe "a batch that raises while being reaped" do
    it "is skipped and alerted, and the rest of the run continues" do
      poison, healthy = Array.new(2) { stale_batch }
      alerts          = []

      Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(message) { alerts << message } }
      allow(SidekiqBatch).to receive(:attempt_completion!).and_call_original
      allow(SidekiqBatch).to receive(:attempt_completion!).with(poison.id).and_raise("boom")

      results = described_class.call(live_jids: Set.new)

      expect(results.map(&:batch)).to eq([healthy])
      expect(alerts.join).to include("##{poison.id}", "boom")
    end
  end

  it "runs the completion check even for a batch it did not have to reap" do
    batch = travel_to(3.hours.ago) do
      b = create(:sidekiq_batch, :running, total_jobs: 1)
      create(:sidekiq_batch_job, :complete, sidekiq_batch: b)
      b
    end

    described_class.call(live_jids: Set.new)

    expect(batch.reload).to be_succeeded_status
  end

  describe "config.stuck_after" do
    it "is what decides how quiet a batch must be" do
      batch = travel_to(30.minutes.ago) do
        b = create(:sidekiq_batch, :running, total_jobs: 1)
        create(:sidekiq_batch_job, sidekiq_batch: b)
        b
      end

      expect(described_class.call(live_jids: Set.new)).to be_empty

      Sidekiq::Batch::Jobs.configure { |c| c.stuck_after = 10.minutes }

      expect(described_class.call(live_jids: Set.new).map(&:batch)).to eq([batch])
    end
  end
end
