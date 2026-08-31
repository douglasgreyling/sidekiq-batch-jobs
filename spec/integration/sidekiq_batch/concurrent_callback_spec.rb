# frozen_string_literal: true

require "spec_helper"
require "concurrent/atomic/cyclic_barrier"

# Second real-concurrency carve-out, alongside concurrent_completion_spec.
#
# `attempt_completion!` reaches #fire_callbacks behind its own atomic UPDATE, so
# only one caller arrives on that path. OrphanedCallbackReaper is a *second*
# caller, and two overlapping reaper runs have nothing serialising them, so each
# event's claim has to be atomic in its own right.
#
# With two events the invariant is per event, not per batch: two threads may
# each deliver one callback. What must never happen is one going out twice.
RSpec.describe "SidekiqBatch concurrent callback firing", :multi_thread do
  it "enqueues each callback exactly once when two callers race" do
    batch = create(:sidekiq_batch, :with_complete_callback, status: "succeeded", completed_at: Time.current)

    barrier = Concurrent::CyclicBarrier.new(2)

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          # Load before the barrier so both threads hold an instance with an
          # empty claim map — exactly the state two reaper runs are in.
          found = SidekiqBatch.find(batch.id)
          barrier.wait
          found.fire_callbacks
        end
      end
    end

    fired = threads.flat_map(&:value)

    expect(fired.map(&:event)).to contain_exactly("complete", "success"),
                                  "expected each event fired exactly once, got: #{fired.inspect}"
    expect(SidekiqBatchTestAlwaysJob.jobs.size).to eq(1)
    expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
    expect(SidekiqBatchTestFailureJob.jobs).to be_empty
    expect(batch.reload.callback_fired_at).to be_present
  end
end
