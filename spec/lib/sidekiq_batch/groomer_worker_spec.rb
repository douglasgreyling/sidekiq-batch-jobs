# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::GroomerWorker do
  it "grooms records past the retention window" do
    travel_to(31.days.ago) { create(:sidekiq_batch, status: "succeeded", completed_at: Time.current) }

    expect { described_class.new.perform }.to change(SidekiqBatch, :count).by(-1)
  end

  it "gives up well before Sidekiq's default retry count" do
    expect(described_class.get_sidekiq_options["retry"]).to eq(3)
  end

  it "runs on the configured maintenance queue" do
    expect(described_class.get_sidekiq_options["queue"]).to eq("default")
  end
end
