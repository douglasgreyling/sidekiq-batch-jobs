# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::OrphanedCallbackReaper do
  # A batch that reached a terminal state but died before enqueueing its
  # callback: status set, callback_fired_at still NULL.
  def orphaned(status:)
    create(:sidekiq_batch, :with_callbacks, status: status, completed_at: Time.current)
  end

  it "fires the success callback for an orphaned succeeded batch" do
    batch = orphaned(status: "succeeded")

    described_class.call

    expect(SidekiqBatchTestFanInJob.jobs.map { |j| j["args"] }).to eq([[batch.id]])
  end

  # A batch owes up to two callbacks, so one batch can produce two Results.
  it "re-fires both of a batch's callbacks and reports each" do
    batch = create(:sidekiq_batch, :with_complete_callback, status: "succeeded", completed_at: Time.current)

    results = described_class.call

    expect(results.map(&:event)).to contain_exactly(:complete, :success)
    expect(results.map(&:batch).uniq).to eq([batch])
    expect(SidekiqBatchTestAlwaysJob.jobs.size).to eq(1)
    expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
  end

  it "fires the failure callback for an orphaned failed batch" do
    batch = orphaned(status: "failed")

    described_class.call

    expect(SidekiqBatchTestFailureJob.jobs.map { |j| j["args"] }).to eq([[batch.id]])
  end

  it "stamps callback_fired_at so the callback cannot go out twice" do
    batch = orphaned(status: "succeeded")

    described_class.call

    expect(batch.reload.callback_fired_at).to be_present
  end

  it "reports what it re-fired" do
    batch = orphaned(status: "succeeded")

    results = described_class.call

    expect(results.size).to eq(1)
    expect(results.first).to have_attributes(
      batch:     batch,
      event:     :success,
      job_class: "SidekiqBatchTestFanInJob"
    )
  end

  it "leaves a batch whose callback already fired alone" do
    orphaned(status: "succeeded").update!(callback_fired_at: Time.current)

    expect(described_class.call).to be_empty
    expect(SidekiqBatchTestFanInJob.jobs).to be_empty
  end

  it "ignores batches that are still running" do
    create(:sidekiq_batch, :with_callbacks, :running)

    expect(described_class.call).to be_empty
  end

  it "reports nothing for a terminal batch with no callback registered" do
    batch = create(:sidekiq_batch, status: "succeeded", completed_at: Time.current)

    expect(described_class.call).to be_empty
    expect(SidekiqBatchTestFanInJob.jobs).to be_empty
    expect(batch.sidekiq_batch_jobs).to be_empty
  end

  # The scope is "terminal with no callback_fired_at". A batch whose outcome
  # has no callback matches that too, and used to keep matching on every run
  # for the whole retention window — so an app registering only :failure had
  # every successful batch of the last 30 days re-examined every 30 minutes.
  it "drains batches whose outcome has no callback instead of rescanning them" do
    create(:sidekiq_batch, status: "succeeded", completed_at: Time.current)

    expect { described_class.call }
      .to change { SidekiqBatch.where(status: %w[succeeded failed], callback_fired_at: nil).count }
      .from(1).to(0)
  end

  it "does not accumulate them across runs" do
    3.times { create(:sidekiq_batch, status: "succeeded", completed_at: Time.current) }

    described_class.call

    expect(SidekiqBatch.where(callback_fired_at: nil)).to be_empty
  end

  # A callback class that will not resolve stays in this scope run after run,
  # because the failed push rolls its claim back. Unguarded, that one batch
  # would block every other orphaned callback in the system until grooming
  # removed it — up to the whole retention window.
  describe "a batch whose callback class cannot be resolved" do
    it "is skipped and alerted, and the rest of the run continues" do
      poison  = create(:sidekiq_batch, status: "succeeded", completed_at: Time.current,
                                      callbacks: { "complete" => "NoSuchWorkerAnywhere" })
      healthy = orphaned(status: "succeeded")
      alerts  = []

      Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(message) { alerts << message } }

      results = described_class.call

      expect(results.map(&:batch)).to eq([healthy])
      expect(SidekiqBatchTestFanInJob.jobs.map { |j| j["args"] }).to eq([[healthy.id]])
      expect(alerts.join).to include("##{poison.id}")
    end

    it "does not stop the run when the alert channel is broken too" do
      create(:sidekiq_batch, status: "succeeded", completed_at: Time.current,
                             callbacks: { "complete" => "NoSuchWorkerAnywhere" })
      healthy = orphaned(status: "succeeded")

      Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(_) { raise "pager is down" } }

      expect(described_class.call.map(&:batch)).to eq([healthy])
    end
  end

  it "is safe to run twice" do
    orphaned(status: "succeeded")

    described_class.call

    expect(described_class.call).to be_empty
    expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
  end
end
