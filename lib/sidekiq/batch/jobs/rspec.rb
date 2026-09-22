# frozen_string_literal: true

require "rspec/core"

# Test-suite wiring, in one require:
#
#   # spec/rails_helper.rb
#   require "sidekiq/batch/jobs/rspec"
#
# Both halves are mechanical, identical in every host, and awkward to work out
# from the symptom. Requiring this is optional; doing it by hand is fine.
RSpec.configure do |config|
  # Transactional fixtures wrap each example in a transaction that is never
  # committed, which is indistinguishable from one the caller opened, so
  # without a baseline every `jobs {}` call in the suite raises
  # TransactionError before enrolling anything.
  #
  # Recording the harness's depth rather than disabling the check keeps the
  # guard live: a transaction the example opens on top of the fixture one still
  # raises, which is the case worth catching. Read from the gem's own model, so
  # it is the same connection the guard measures.
  config.before do
    Thread.current[::SidekiqBatch::BatchEnrollmentContext::TXN_BASELINE] =
      ::SidekiqBatchJob.connection.open_transactions
  end

  # Cleared so a stale baseline cannot hide a real transaction in a later
  # example that runs outside this hook.
  config.after do
    Thread.current[::SidekiqBatch::BatchEnrollmentContext::TXN_BASELINE] = nil
  end

  # `install!` only adds the server middleware when `Sidekiq.server?` is true,
  # which it never is under RSpec. Without this, inline jobs run and nothing
  # marks their rows complete, so batches never finish and callbacks never
  # fire, with nothing raised to say why. That silence is the reason this is
  # worth shipping rather than documenting.
  #
  # In `before(:suite)` so the host can require its Sidekiq testing API either
  # side of this file. Harmless under fake mode, where no job runs.
  config.before(:suite) do
    next unless defined?(::Sidekiq::Testing)

    ::Sidekiq::Testing.server_middleware { |chain| chain.add(::SidekiqBatch::Middleware) }
  end
end
