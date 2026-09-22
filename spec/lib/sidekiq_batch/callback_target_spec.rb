# frozen_string_literal: true

require "spec_helper"

# A callback is enqueued by the gem, never called inline, so the only thing
# that matters about its class is which enqueue method it answers to. These
# cover both accepted shapes and the refusal in between.
RSpec.describe SidekiqBatch::CallbackTarget do
  describe ".supported?" do
    it "accepts a Sidekiq worker" do
      expect(described_class).to be_supported(SidekiqBatchTestFanInJob)
    end

    it "accepts an ActiveJob class" do
      expect(described_class).to be_supported(SidekiqBatchTestActiveJobCallback)
    end

    it "rejects a class that answers to neither enqueue method" do
      expect(described_class).not_to be_supported(SidekiqBatchUnenqueueableCallback)
    end
  end

  describe ".enqueue" do
    it "pushes a Sidekiq worker with perform_async" do
      expect { described_class.enqueue(SidekiqBatchTestFanInJob, 7) }
        .to change { SidekiqBatchTestFanInJob.jobs.size }.by(1)

      expect(SidekiqBatchTestFanInJob.jobs.last["args"]).to eq([7])
    end

    # The wrapper is what Sidekiq's ActiveJob adapter pushes, and `wrapped` is
    # what carries the real class through to the worker.
    it "pushes an ActiveJob through Sidekiq's wrapper, on the queue it declared" do
      described_class.enqueue(SidekiqBatchTestActiveJobCallback, 7)

      payload = Sidekiq::Queues["callbacks"].last

      # Named through the adapter, because Rails 7.2 and Sidekiq 7.3 disagree
      # with Sidekiq 8 about which class that is.
      expect(payload["class"]).to eq(ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.name)
      expect(payload["wrapped"]).to eq("SidekiqBatchTestActiveJobCallback")
      expect(payload.dig("args", 0, "arguments")).to eq([7])
    end

    # The reason this builds the payload itself rather than calling
    # `perform_later`. Sidekiq's adapter declares
    # `enqueue_after_transaction_commit?`, so `perform_later` hands the push to
    # an after-commit hook: inside the block nothing would be queued yet, and
    # the claim would reach the database first. Announcement needs the opposite
    # order, so that a failure between the two rolls the claim back and leaves
    # the reaper something to retry.
    #
    # Measured inside the block, which is the only place the difference shows.
    it "enqueues an ActiveJob synchronously, not deferred past the commit" do
      queued_inside_transaction = nil

      SidekiqBatch.transaction do
        described_class.enqueue(SidekiqBatchTestActiveJobCallback, 7)

        queued_inside_transaction = Sidekiq::Queues["callbacks"].size
      end

      expect(queued_inside_transaction).to eq(1)
    end
  end

  describe ".unsupported_message" do
    it "names both interfaces when the class is not a job at all" do
      message = described_class.unsupported_message(SidekiqBatchUnenqueueableCallback)

      expect(message).to include("perform_async").and include("perform_later")
    end

    # Reached only when `supported?` said no, which for an ActiveJob class
    # means the Sidekiq adapter was never loaded. A different mistake from
    # registering something that is not a job, so it gets a different message.
    it "points at the missing adapter when the class is an ActiveJob" do
      message = described_class.unsupported_message(SidekiqBatchTestActiveJobCallback)

      expect(message).to include("ActiveJob").and include("adapter is not loaded")
    end
  end
end
