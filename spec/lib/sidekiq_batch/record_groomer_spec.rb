# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::RecordGroomer do
  def batch_created(ago, status:)
    travel_to(ago.ago) { create(:sidekiq_batch, status: status, completed_at: Time.current) }
  end

  it "deletes terminal batches older than the retention window" do
    old = batch_created(31.days, status: "succeeded")

    expect { described_class.call }.to change(SidekiqBatch, :count).by(-1)
    expect(SidekiqBatch.where(id: old.id)).to be_empty
  end

  it "deletes failed batches too" do
    batch_created(31.days, status: "failed")

    expect { described_class.call }.to change(SidekiqBatch, :count).by(-1)
  end

  it "keeps terminal batches inside the window" do
    batch_created(29.days, status: "succeeded")

    expect { described_class.call }.not_to change(SidekiqBatch, :count)
  end

  # Deliberate: age is measured from created_at, so a batch that ran for weeks is
  # groomed sooner than one that finished immediately. A completed_at-based
  # groomer would keep this row; this one deletes it.
  it "measures age from created_at, not completed_at" do
    long_running = travel_to(31.days.ago) { create(:sidekiq_batch, status: "running") }
    long_running.update!(status: "succeeded", completed_at: Time.current)

    expect { described_class.call }.to change(SidekiqBatch, :count).by(-1)
  end

  it "keeps running batches however old they are" do
    batch_created(90.days, status: "running")

    expect { described_class.call }.not_to change(SidekiqBatch, :count)
  end

  # The backstop for a `jobs {}` block killed before it could start its batch,
  # on hosts that never scheduled AbandonedEnrollmentReaper. Left alone these
  # accumulate for the life of the table: nothing else looks at `pending`.
  describe "abandoned pending batches" do
    it "deletes one that is long past the retention window" do
      batch_created(90.days, status: "pending")

      expect { described_class.call }.to change(SidekiqBatch, :count).by(-1)
    end

    it "keeps a recent one, which may still be enrolling" do
      batch_created(1.hour, status: "pending")

      expect { described_class.call }.not_to change(SidekiqBatch, :count)
    end

    # Deleting a pending batch before the reaper can adopt it destroys live
    # data — the enrolled jobs still run, and nothing records their outcome. So
    # the pending cutoff never drops below what the reaper needs, however short
    # retention is set.
    it "waits for the reaper even when retention is shorter than stuck_after" do
      Sidekiq::Batch::Jobs.configure do |c|
        c.retention   = 1.minute
        c.stuck_after = 2.hours
      end

      batch_created(1.hour, status: "pending")

      expect { described_class.call }.not_to change(SidekiqBatch, :count)
    end
  end

  it "returns how many it deleted" do
    2.times { batch_created(31.days, status: "succeeded") }

    expect(described_class.call).to eq(2)
  end

  # delete_all skips dependent: :destroy, so the child rows rely entirely on the
  # foreign key's ON DELETE CASCADE. Worth pinning down.
  it "takes the batch's jobs with it via the foreign key cascade" do
    old = batch_created(31.days, status: "succeeded")
    create_list(:sidekiq_batch_job, 3, sidekiq_batch: old)

    expect { described_class.call }.to change(SidekiqBatchJob, :count).by(-3)
  end

  # The cascade means one unbounded DELETE can carry tens of millions of child
  # rows in a single transaction. Chunking has to delete everything eligible
  # without skipping rows as the cursor advances over what it just removed.
  describe "chunked deletion" do
    before { stub_const("#{described_class}::CHUNK_SIZE", 2) }

    it "deletes every eligible batch across several chunks" do
      5.times { batch_created(31.days, status: "succeeded") }

      expect(described_class.call).to eq(5)
      expect(SidekiqBatch.count).to eq(0)
    end

    it "still leaves batches inside the window alone" do
      5.times { batch_created(31.days, status: "succeeded") }
      keep = batch_created(1.day, status: "succeeded")

      described_class.call

      expect(SidekiqBatch.pluck(:id)).to eq([keep.id])
    end

    it "takes the child rows of every chunk with it" do
      5.times { create_list(:sidekiq_batch_job, 2, sidekiq_batch: batch_created(31.days, status: "succeeded")) }

      expect { described_class.call }.to change(SidekiqBatchJob, :count).by(-10)
    end
  end

  it "honours a reconfigured retention window" do
    batch_created(10.days, status: "succeeded")

    expect { described_class.call }.not_to change(SidekiqBatch, :count)

    Sidekiq::Batch::Jobs.configure { |c| c.retention = 7.days }

    expect { described_class.call }.to change(SidekiqBatch, :count).by(-1)
  end
end
