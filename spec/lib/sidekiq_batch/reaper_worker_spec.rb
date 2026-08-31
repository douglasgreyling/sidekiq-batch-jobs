# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::ReaperWorker do
  subject(:worker) { described_class.new }

  let(:alerts) { [] }

  before do
    Sidekiq::Batch::Jobs.configure { |config| config.on_alert = ->(message) { alerts << message } }
    allow(SidekiqBatch::JidIndex).to receive(:call).and_return(Set.new)
  end

  def stale_batch(job_count: 1, description: "nightly rescore")
    travel_to(3.hours.ago) do
      batch = create(:sidekiq_batch, :running, description: description, total_jobs: job_count)
      create_list(:sidekiq_batch_job, job_count, sidekiq_batch: batch)
      batch
    end
  end

  it "runs both recoveries in one pass" do
    stuck    = stale_batch
    orphaned = create(:sidekiq_batch, :with_callbacks, status: "succeeded", completed_at: Time.current)

    worker.perform

    expect(stuck.reload).to be_failed_status
    expect(orphaned.reload.callback_fired_at).to be_present
  end

  it "builds the jid index exactly once per run, however many batches it examines" do
    2.times { stale_batch }

    worker.perform

    expect(SidekiqBatch::JidIndex).to have_received(:call).once
  end

  it "says nothing when there is nothing to fix" do
    create(:sidekiq_batch, :running, total_jobs: 1)

    worker.perform

    expect(alerts).to be_empty
  end

  describe "the abandoned-enrollment alert" do
    it "names the batch and how many jobs it was started with" do
      batch = travel_to(3.hours.ago) do
        b = create(:sidekiq_batch, description: "nightly import")
        create_list(:sidekiq_batch_job, 2, sidekiq_batch: b)
        b
      end

      worker.perform

      expect(alerts.first).to include("##{batch.id}", "nightly import", "never finished enrolling", "2 job(s)")
    end
  end

  describe "the stuck-jobs alert" do
    it "names the batch, the count and the jids" do
      batch = stale_batch
      jid   = batch.sidekiq_batch_jobs.first.jid

      worker.perform

      expect(alerts.size).to eq(1)
      expect(alerts.first).to include("##{batch.id}", "nightly rescore", "1 stuck job(s)", jid, "`failed`")
    end

    it "truncates a long jid list rather than dumping hundreds into a chat message" do
      stale_batch(job_count: 8)

      worker.perform

      expect(alerts.first).to include("8 stuck job(s)", "…(+3 more)")
    end

    it "falls back to a placeholder when the batch has no description" do
      stale_batch(description: nil)

      worker.perform

      expect(alerts.first).to include("(no description)")
    end
  end

  describe "the orphaned-callback alert" do
    it "names the batch, the event and the callback that was re-fired" do
      batch = create(:sidekiq_batch, :with_callbacks, status: "succeeded", completed_at: Time.current)

      worker.perform

      expect(alerts.size).to eq(1)
      expect(alerts.first).to include("##{batch.id}", "`success`", "SidekiqBatchTestFanInJob")
    end
  end

  it "stays quiet when alerting is switched off" do
    Sidekiq::Batch::Jobs.configure { |config| config.on_alert = nil }
    stale_batch

    expect { worker.perform }.not_to raise_error
  end

  # Idempotent cron work: the next scheduled run does the same job, so a
  # persistent failure should surface rather than retry for weeks on the
  # default 25.
  it "gives up well before Sidekiq's default retry count" do
    expect(described_class.get_sidekiq_options["retry"]).to eq(3)
  end

  it "runs on the configured maintenance queue" do
    expect(described_class.get_sidekiq_options["queue"]).to eq("default")
  end
end
