# frozen_string_literal: true

require "sidekiq/testing"

# Fake mode by default — pushes land in Worker.jobs and can be drained
# deterministically. Inline mode is forbidden for SidekiqBatch specs (it
# runs the job synchronously inside perform_async, while the thread-local
# enrollment flag is still set — the resulting semantics mask real bugs).
Sidekiq::Testing.fake!

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

    Thread.current[SidekiqBatch::BatchEnrollmentContext::TXN_BASELINE] =
      ActiveRecord::Base.connection.open_transactions
  end

  config.after do
    Thread.current[SidekiqBatch::BatchEnrollmentContext::TXN_BASELINE] = nil
  end
end
