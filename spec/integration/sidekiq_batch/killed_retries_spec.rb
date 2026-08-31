# frozen_string_literal: true

require "spec_helper"
require "sidekiq/api"

# Driven against a real Redis, because the whole point is what Sidekiq's own
# bulk-kill does to jobs the gem is tracking. "Kill All" on the Retries page
# moves every job to the dead set with `notify_failure: false`, so the death
# handler never runs and the enrollment rows are left `pending` with nothing
# but the reaper able to finish them.
RSpec.describe "a batch whose retries were killed from the Sidekiq web UI" do
  around { |example| Sidekiq::Testing.disable! { example.run } }

  before { Sidekiq.redis(&:flushdb) }
  after  { Sidekiq.redis(&:flushdb) }

  let(:batch) do
    travel_to(3.hours.ago) do
      created = create(:sidekiq_batch, :running, total_jobs: 1)
      create(:sidekiq_batch_job, sidekiq_batch: created)
      created
    end
  end

  let(:job) { batch.sidekiq_batch_jobs.first }

  before do
    push_to_retry_set(job.jid)

    Sidekiq::RetrySet.new.kill_all
  end

  it "leaves the row pending, because a bulk kill runs no death handler" do
    expect(Sidekiq::DeadSet.new.size).to eq(1)
    expect(job.reload).to be_pending_status
  end

  it "is finished by the reaper rather than waiting for the dead set to expire" do
    SidekiqBatch::StuckJobReaper.call

    expect(job.reload).to be_failed_status
    expect(batch.reload).to be_failed_status
  end

  it "announces its outcome, so nothing is left waiting on a callback" do
    SidekiqBatch::StuckJobReaper.call

    expect(batch.reload.callback_fired_at).to be_present
  end

  def push_to_retry_set(jid)
    payload = {
      "class"                            => "SidekiqBatchTestWorker",
      "args"                             => [1],
      "queue"                            => "default",
      "jid"                              => jid,
      SidekiqBatch::PAYLOAD_BATCH_ID_KEY => batch.id
    }

    Sidekiq.redis { |conn| conn.zadd("retry", Time.now.to_f.to_s, Sidekiq.dump_json(payload)) }
  end
end
