# frozen_string_literal: true

require "spec_helper"
require "sidekiq/api"

# Exercised against a real Redis rather than stubs. JidIndex is a thin adapter
# over five different Sidekiq storage layouts, so stubbing it would assert only
# that we call the methods we call — and the shapes are exactly what shifts
# between Sidekiq versions (Sidekiq::Work stopped being a Hash in 7.0).
RSpec.describe SidekiqBatch::JidIndex do
  around do |example|
    Sidekiq::Testing.disable! { example.run }
  end

  before { Sidekiq.redis(&:flushdb) }
  after  { Sidekiq.redis(&:flushdb) }

  it "returns a Set, so membership checks stay O(1) across many pending rows" do
    expect(described_class.call).to be_a(Set)
  end

  it "is empty when Sidekiq has no work at all" do
    expect(described_class.call).to be_empty
  end

  it "includes jobs waiting in a queue" do
    jid = SidekiqBatchTestWorker.perform_async(1)

    expect(described_class.call).to include(jid)
  end

  it "includes jobs scheduled for later" do
    jid = SidekiqBatchTestWorker.perform_in(1.hour, 1)

    expect(described_class.call).to include(jid)
  end

  it "includes jobs waiting to be retried" do
    jid = "retryjid0000000000000001"
    push_to_sorted_set("retry", jid)

    expect(described_class.call).to include(jid)
  end

  # A dead job will never run again, so treating it as live only stops the
  # reaper from finishing a batch that is waiting on it. `notify_failure: false`
  # here is not a testing shortcut: it is exactly what "Kill All" on the Retries
  # page passes, so no death handler marks the row and the reaper is the only
  # thing left that can.
  it "excludes jobs in the dead set" do
    jid = "deadjid00000000000000001"
    Sidekiq::DeadSet.new.kill(Sidekiq.dump_json(payload_for(jid)), notify_failure: false)

    expect(described_class.call).not_to include(jid)
  end

  # The branch most exposed to Sidekiq upgrades: WorkSet yields Sidekiq::Work
  # objects, and reading the payload off one changed shape in 7.0.
  it "includes jobs executing right now" do
    jid = "runningjid000000000000001"
    register_running_job(jid)

    expect(described_class.call).to include(jid)
  end

  # Guards the fixture rather than the code. If `payload` is ever written back
  # as a nested Hash, the example above passes again while production stays
  # broken, which is exactly how a wrong read of this branch survived to 0.3.0.
  it "is set up the way a real Sidekiq process writes it, with payload a JSON string" do
    register_running_job("runningjid000000000000001")

    _process_id, _thread_id, work = Sidekiq::WorkSet.new.first

    expect(work.payload).to be_a(String)
  end

  # The specific way it broke: `payload["jid"]` on that string is String
  # indexing, so it finds the key *name* in the JSON and returns the literal
  # "jid" for every job on the cluster. The index filled with one constant, so
  # no executing job was ever found in it and StuckJobReaper failed rows whose
  # jobs were running perfectly well.
  it "never collects the literal string 'jid'" do
    register_running_job("runningjid000000000000001")

    expect(described_class.call).not_to include("jid")
  end

  # Sidekiq yielded a raw Hash here until 7.3 and a Sidekiq::Work since, and
  # the gemspec supports from 7.0. The old shape cannot be produced against the
  # Sidekiq this suite resolves, so this is the one place a stub earns its keep:
  # the alternative is shipping an untested branch for versions we promise.
  it "reads the pre-7.3 shape, where WorkSet yields a raw Hash" do
    jid = "runningjid000000000000001"
    raw = { "queue"   => "default",
            "run_at"  => Time.now.to_i,
            "payload" => Sidekiq.dump_json(payload_for(jid)) }

    work_set = instance_double(Sidekiq::WorkSet)
    allow(Sidekiq::WorkSet).to receive(:new).and_return(work_set)
    allow(work_set).to receive(:each).and_yield("host:1:abcdef", "tid-1", raw)

    expect(described_class.call).to include(jid)
  end

  it "does not invent jids that are nowhere in Sidekiq" do
    SidekiqBatchTestWorker.perform_async(1)

    expect(described_class.call).not_to include("absentjid00000000000000")
  end

  def payload_for(jid)
    { "class" => "SidekiqBatchTestWorker", "args" => [1], "queue" => "default", "jid" => jid }
  end

  def push_to_sorted_set(key, jid)
    Sidekiq.redis do |conn|
      conn.zadd(key, Time.now.to_f.to_s, Sidekiq.dump_json(payload_for(jid)))
    end
  end

  # Mirrors the heartbeat layout a live Sidekiq process writes: a member in the
  # `processes` set, and a `<key>:work` hash keyed by thread id.
  def register_running_job(jid)
    process_key = "host:1:abcdef"

    Sidekiq.redis do |conn|
      conn.sadd("processes", [process_key])
      conn.hset("#{process_key}:work", "tid-1", work_entry_for(jid))
    end
  end

  # `payload` is a JSON *string*, not a nested object. Straight from the
  # processor: `WORK_STATE.set(tid, {queue:, payload: jobstr, run_at:})`, where
  # `jobstr` is the job as it came off the queue. Nesting a Hash here instead is
  # what let a broken read of this branch pass for three releases.
  def work_entry_for(jid)
    Sidekiq.dump_json(
      "queue"   => "default",
      "run_at"  => Time.now.to_i,
      "payload" => Sidekiq.dump_json(payload_for(jid))
    )
  end
end
