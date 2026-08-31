# frozen_string_literal: true

require "spec_helper"
require "concurrent/atomic/cyclic_barrier"

# Real-concurrency carve-out. The atomic UPDATE in
# SidekiqBatch#attempt_completion! is the design's single race-safety claim:
# two workers completing the last two jobs at once must fire exactly ONE
# callback. Single-threaded fake-mode tests cannot prove that, because the
# correctness lives in Postgres's row-level locking on the UPDATE.
RSpec.describe "SidekiqBatch concurrent completion", :multi_thread do
  it "fires the callback exactly once when two threads race the completion UPDATE" do
    batch = create(:sidekiq_batch, :with_callbacks, status: "running", total_jobs: 2)
    create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
    create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)

    barrier = Concurrent::CyclicBarrier.new(2)

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          SidekiqBatch.find(batch.id).attempt_completion!
        end
      end
    end

    results = threads.map(&:value)
    winners = results.compact

    expect(winners.size).to eq(1), "expected exactly one thread to win, got: #{results.inspect}"

    batch.reload
    expect(batch.status).to eq("succeeded")
    expect(batch.callback_fired_at).to be_present
    expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
  end
end
