# frozen_string_literal: true

require "sidekiq/testing"

# The suite runs the wiring the gem ships to hosts, rather than its own copy,
# so the helper cannot rot without a failure here. It sets the enrollment
# transaction baseline that transactional fixtures otherwise trip, and adds the
# server middleware that Sidekiq::Testing would not get from `install!`.
require "sidekiq/batch/jobs/rspec"

# Fake mode by default — pushes land in Worker.jobs and can be drained
# deterministically. Inline mode is forbidden for SidekiqBatch specs (it
# runs the job synchronously inside perform_async, while the thread-local
# enrollment flag is still set — the resulting semantics mask real bugs).
Sidekiq::Testing.fake!

# Callbacks may also be ActiveJob classes, which are enqueued through Sidekiq's
# wrapper rather than with perform_async. See SidekiqBatch::CallbackTarget.
ActiveJob::Base.queue_adapter = :sidekiq
ActiveJob::Base.logger        = Logger.new(IO::NULL)

class SidekiqBatchTestActiveJobCallback < ActiveJob::Base
  queue_as :callbacks

  def self.fired
    @fired ||= []
  end

  def self.reset!
    @fired = []
  end

  def perform(batch_id)
    self.class.fired << batch_id
  end
end

# Neither a Sidekiq worker nor an ActiveJob, so nothing can enqueue it.
class SidekiqBatchUnenqueueableCallback
  def perform(batch_id); end
end

# Test workers used by enrollment / middleware / integration specs.
class SidekiqBatchTestWorker
  include Sidekiq::Worker

  def perform(*); end
end

class SidekiqBatchBoomWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(*)
    raise "boom"
  end
end

class SidekiqBatchRetryingWorker
  include Sidekiq::Worker
  sidekiq_options retry: 2

  def perform(*)
    raise "boom"
  end
end

class SidekiqBatchTestFanInJob
  include Sidekiq::Worker

  def self.fired
    @fired ||= []
  end

  def self.reset!
    @fired = []
  end

  def perform(batch_id)
    self.class.fired << batch_id
  end
end

class SidekiqBatchTestFailureJob
  include Sidekiq::Worker

  def self.fired
    @fired ||= []
  end

  def self.reset!
    @fired = []
  end

  def perform(batch_id)
    self.class.fired << batch_id
  end
end

# For the `complete` event, which fires whatever the outcome.
class SidekiqBatchTestAlwaysJob
  include Sidekiq::Worker

  def self.fired
    @fired ||= []
  end

  def self.reset!
    @fired = []
  end

  def perform(batch_id)
    self.class.fired << batch_id
  end
end

RSpec.configure do |config|
  config.before do
    Sidekiq::Worker.clear_all
    SidekiqBatchTestFanInJob.reset!
    SidekiqBatchTestFailureJob.reset!
    SidekiqBatchTestAlwaysJob.reset!
    SidekiqBatchTestActiveJobCallback.reset!
  end
end
