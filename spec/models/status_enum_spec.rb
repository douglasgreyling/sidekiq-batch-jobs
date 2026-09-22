# frozen_string_literal: true

require "spec_helper"

# The `enum` call on each model is the most version-fragile line in the gem:
# its signature moved twice inside the range Rails has shipped, and ActiveRecord
# 8 dropped the hash form that 6.1 required. These examples pin the surface that
# call has to produce, so a Rails upgrade that changes it again shows up here
# rather than as a confusing failure somewhere downstream.
RSpec.describe "the status enum" do
  describe "SidekiqBatch" do
    it "maps every status to its column value" do
      expect(SidekiqBatch.statuses).to eq(
        "pending" => 0, "running" => 1, "succeeded" => 2, "failed" => 3
      )
    end

    it "defines suffixed predicates rather than bare ones" do
      batch = build(:sidekiq_batch, status: "running")

      expect(batch).to be_running_status
      expect(batch).not_to be_pending_status
      expect(batch).not_to respond_to(:running?)
    end

    it "defines suffixed scopes" do
      running = create(:sidekiq_batch, status: "running")
      create(:sidekiq_batch, status: "pending")

      expect(SidekiqBatch.running_status).to contain_exactly(running)
    end
  end

  describe "SidekiqBatchJob" do
    it "maps every status to its column value" do
      expect(SidekiqBatchJob.statuses).to eq(
        "pending" => 0, "complete" => 1, "failed" => 2
      )
    end

    it "defines suffixed predicates rather than bare ones" do
      job = build(:sidekiq_batch_job, status: "failed")

      expect(job).to be_failed_status
      expect(job).not_to be_pending_status
      expect(job).not_to respond_to(:failed?)
    end

    it "defines suffixed scopes" do
      failed = create(:sidekiq_batch_job, :failed)
      create(:sidekiq_batch_job)

      expect(SidekiqBatchJob.failed_status).to contain_exactly(failed)
    end
  end
end
