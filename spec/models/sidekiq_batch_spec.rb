# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch, type: :model do
  subject { build(:sidekiq_batch) }

  # delete_all, not destroy: the FK is ON DELETE CASCADE, and destroy would load
  # and destroy a 100k-job batch's children one row at a time.
  it { is_expected.to have_many(:sidekiq_batch_jobs).dependent(:delete_all) }

  describe "status enum" do
    it "rejects an unknown status at assignment time" do
      expect { described_class.new(status: "bogus") }.to raise_error(ArgumentError)
    end
  end

  describe "#failure_policy=" do
    it "spreads a tolerance across the two columns it is stored in" do
      batch = create(:sidekiq_batch, failure_policy: { tolerate: "5%" })

      expect(batch.reload).to have_attributes(failure_policy: "tolerate_percent", failure_tolerance: 5)
    end

    it "clears the tolerance when moving to a policy that has none" do
      batch = create(:sidekiq_batch, failure_policy: { tolerate: 10 })

      batch.update!(failure_policy: :any_failure)

      expect(batch.reload.failure_tolerance).to be_nil
    end

    it "rejects a policy it cannot make sense of" do
      expect { build(:sidekiq_batch, failure_policy: :mostly_fine) }
        .to raise_error(ArgumentError, /unknown failure policy/)
    end

    it "falls back to the host's configured default" do
      Sidekiq::Batch::Jobs.configure { |c| c.failure_policy = { tolerate: 3 } }

      expect(create(:sidekiq_batch))
        .to have_attributes(failure_policy: "tolerate_jobs", failure_tolerance: 3)
    end

    it "lets an explicit policy win over the configured default" do
      Sidekiq::Batch::Jobs.configure { |c| c.failure_policy = { tolerate: 3 } }

      expect(create(:sidekiq_batch, failure_policy: :all_failed))
        .to have_attributes(failure_policy: "all_failed", failure_tolerance: nil)
    end

    # The writer keeps the pair consistent, but update_all and a direct
    # attribute write both go around it.
    it "rejects a tolerating policy left without a number" do
      batch                   = build(:sidekiq_batch, failure_policy: { tolerate: 10 })
      batch.failure_tolerance = nil

      expect(batch).not_to be_valid
      expect(batch.errors[:failure_tolerance]).to include(/is required/)
    end

    it "rejects a number hung off a policy that ignores it" do
      batch                   = build(:sidekiq_batch, failure_policy: :all_failed)
      batch.failure_tolerance = 5

      expect(batch).not_to be_valid
      expect(batch.errors[:failure_tolerance]).to include(/only applies/)
    end
  end

  describe "#on" do
    let(:batch) { create(:sidekiq_batch) }

    it "persists the callback class name as a string" do
      batch.on(:complete, SidekiqBatchTestFanInJob)

      expect(batch.reload.callbacks).to eq("complete" => "SidekiqBatchTestFanInJob")
    end

    it "accepts a string job class" do
      batch.on("failure", "SidekiqBatchTestFailureJob")

      expect(batch.reload.callbacks).to eq("failure" => "SidekiqBatchTestFailureJob")
    end

    it "raises for unknown events" do
      expect { batch.on(:wat, "X") }.to raise_error(ArgumentError, /unknown event/)
    end

    it "accepts registration while the batch is still running" do
      running = create(:sidekiq_batch, :running)

      running.on(:complete, SidekiqBatchTestFanInJob)

      expect(running.reload.callbacks).to eq("complete" => "SidekiqBatchTestFanInJob")
    end

    # The announcement has already happened and the claim is spent, so a
    # callback registered now would silently never fire.
    %w[succeeded failed].each do |terminal_status|
      it "raises when the batch is already #{terminal_status}" do
        finished = create(:sidekiq_batch, status: terminal_status, completed_at: Time.current)

        expect { finished.on(:complete, SidekiqBatchTestFanInJob) }
          .to raise_error(ArgumentError, /already finished/)
      end
    end
  end

  describe "#progress" do
    let(:batch) { create(:sidekiq_batch, :running, total_jobs: 3) }

    before do
      create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
      create(:sidekiq_batch_job, :failed,   sidekiq_batch: batch)
      create(:sidekiq_batch_job,            sidekiq_batch: batch)
    end

    it "returns counts by status plus total" do
      expect(batch.progress).to eq(total: 3, complete: 1, failed: 1, pending: 1)
    end
  end

  describe "#percentage_progress" do
    it "is 0.0 when the batch has no jobs" do
      expect(build(:sidekiq_batch, total_jobs: 0).percentage_progress).to eq(0.0)
    end

    it "is 0.0 when nothing has finished" do
      expect(create(:sidekiq_batch, :with_all_jobs_pending).percentage_progress).to eq(0.0)
    end

    it "is 100.0 when every job completed" do
      expect(create(:sidekiq_batch, :with_all_jobs_complete).percentage_progress).to eq(100.0)
    end

    it "counts failed jobs as finished" do
      expect(create(:sidekiq_batch, :with_all_jobs_failed).percentage_progress).to eq(100.0)
    end

    it "counts both terminal states against the total" do
      expect(create(:sidekiq_batch, :with_mixed_jobs).percentage_progress).to eq(50.0)
    end

    it "rounds to two decimal places" do
      batch = create(:sidekiq_batch, :running, total_jobs: 3)
      create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)

      expect(batch.percentage_progress).to eq(33.33)
    end
  end

  describe "#eta" do
    it "is nil unless the batch is running" do
      expect(build(:sidekiq_batch).eta).to be_nil
      expect(build(:sidekiq_batch, status: "succeeded").eta).to be_nil
      expect(build(:sidekiq_batch, status: "failed").eta).to be_nil
    end

    it "is nil when the batch has no jobs" do
      expect(build(:sidekiq_batch, :running, total_jobs: 0).eta).to be_nil
    end

    it "is nil when nothing has finished, since there is no throughput to project" do
      expect(create(:sidekiq_batch, :with_all_jobs_pending).eta).to be_nil
    end

    it "is zero once every job completed" do
      expect(create(:sidekiq_batch, :with_all_jobs_complete).eta).to eq(0.seconds)
    end

    it "counts failed jobs as finished and is zero" do
      expect(create(:sidekiq_batch, :with_all_jobs_failed).eta).to eq(0.seconds)
    end

    context "when some jobs have finished" do
      let(:batch) do
        travel_to(100.seconds.ago) { create(:sidekiq_batch, :running, total_jobs: 4) }
      end

      before do
        batch
        create_list(:sidekiq_batch_job, 2, :complete, sidekiq_batch: batch)
        create_list(:sidekiq_batch_job, 2, sidekiq_batch: batch)
      end

      it "returns an ActiveSupport::Duration" do
        expect(batch.eta).to be_a(ActiveSupport::Duration)
      end

      it "projects the remaining time from observed throughput" do
        # 2 of 4 done in ~100s → ~0.02 jobs/s; 2 remaining → ~100s to go.
        expect(batch.eta).to be_within(1.second).of(100.seconds)
      end
    end
  end

  describe "#attempt_completion!" do
    let(:batch) { create(:sidekiq_batch, :running, total_jobs: 2) }

    before do
      batch.on(:success, SidekiqBatchTestFanInJob)
      batch.on(:failure, SidekiqBatchTestFailureJob)
    end

    context "when pending jobs remain" do
      before do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job,            sidekiq_batch: batch)
      end

      it "returns nil and does not transition" do
        expect(batch.attempt_completion!).to be_nil
        expect(batch.reload.status).to eq("running")
      end
    end

    context "when all jobs are complete" do
      before do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
      end

      it "transitions to succeeded and fires the success callback" do
        expect(batch.attempt_completion!).to eq("succeeded")
        batch.reload

        expect(batch.status).to eq("succeeded")
        expect(batch.completed_at).to be_present
        expect(batch.callback_fired_at).to be_present
        expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestFanInJob.jobs.first["args"]).to eq([batch.id])
      end
    end

    context "when at least one job failed" do
      before do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job, :failed,   sidekiq_batch: batch)
      end

      it "transitions to failed and fires the failure callback" do
        expect(batch.attempt_completion!).to eq("failed")

        expect(batch.reload.status).to eq("failed")
        expect(SidekiqBatchTestFailureJob.jobs.size).to eq(1)
      end

      it "does not fire the success callback" do
        batch.attempt_completion!

        expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      end
    end

    # The whole point of the third event: one worker that runs whatever
    # happened, alongside the one that names what happened.
    context "with a callback on the outcome-agnostic event too" do
      let(:batch) { create(:sidekiq_batch, :running, :with_complete_callback, total_jobs: 1) }

      it "fires it alongside the success callback" do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)

        batch.attempt_completion!

        expect(SidekiqBatchTestAlwaysJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestFailureJob.jobs).to be_empty
      end

      it "fires it alongside the failure callback" do
        create(:sidekiq_batch_job, :failed, sidekiq_batch: batch)

        batch.attempt_completion!

        expect(SidekiqBatchTestAlwaysJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestFailureJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      end
    end

    context "when already terminal" do
      before do
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        batch.attempt_completion!
        SidekiqBatchTestFanInJob.clear
      end

      it "returns nil on a second call and does not re-fire the callback" do
        expect(batch.attempt_completion!).to be_nil
        expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      end
    end

    context "with no callback registered for the event" do
      let(:batch) { create(:sidekiq_batch, :running, total_jobs: 1) }

      before do
        batch.update!(callbacks: {})
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
      end

      it "still transitions status but fires nothing" do
        expect(batch.attempt_completion!).to eq("succeeded")
        expect(SidekiqBatchTestFanInJob.jobs).to be_empty
        expect(SidekiqBatchTestFailureJob.jobs).to be_empty
      end

      # Claimed even though nothing went out, so the batch does not sit in the
      # orphaned-callback scope being rescanned until grooming removes it.
      it "claims the batch so the orphaned-callback reaper stops seeing it" do
        batch.attempt_completion!

        expect(batch.reload.callback_fired_at).to be_present
        expect(SidekiqBatch::OrphanedCallbackReaper.call).to be_empty
      end
    end
  end

  describe "#fire_callbacks" do
    # Terminal, because that is the only state with an outcome to announce —
    # both internal callers arrive here having just transitioned the batch.
    let(:batch) { create(:sidekiq_batch, :with_complete_callback, status: "succeeded", completed_at: Time.current) }

    let(:alerts) { [] }

    before { Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(message) { alerts << message } } }

    it "reports every callback it enqueued" do
      expect(batch.fire_callbacks.map(&:to_h)).to contain_exactly(
        { event: "complete", job_class: "SidekiqBatchTestAlwaysJob" },
        { event: "success",  job_class: "SidekiqBatchTestFanInJob" }
      )
    end

    it "is a no-op if called a second time on the same batch" do
      batch.fire_callbacks
      first_fired_at = batch.reload.callback_fired_at
      Sidekiq::Worker.clear_all

      expect(batch.fire_callbacks).to be_empty
      expect(SidekiqBatchTestAlwaysJob.jobs).to be_empty
      expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      expect(batch.reload.callback_fired_at).to eq(first_fired_at)
    end

    it "reports nothing when no callback is registered for either event" do
      plain = create(:sidekiq_batch, status: "succeeded", completed_at: Time.current)

      expect(plain.fire_callbacks).to be_empty
    end

    # Nothing was sent, but the announcement is resolved. Without the claim the
    # batch matches the orphaned-callback scope forever, and every batch whose
    # outcome has no callback accumulates there until grooming deletes it.
    it "still claims the batch when there is nothing to send" do
      plain = create(:sidekiq_batch, status: "succeeded", completed_at: Time.current)

      plain.fire_callbacks

      expect(plain.callback_fired_at).to be_present
      expect(plain.reload.callback_fired_at).to be_present
    end

    # Firing early would spend the claim before the batch has an outcome,
    # permanently suppressing the real callbacks when it does finish.
    %i[pending running].each do |unfinished|
      it "refuses to fire on a #{unfinished} batch, leaving the claim unspent" do
        live = create(:sidekiq_batch, :with_complete_callback, status: unfinished.to_s)

        expect(live.fire_callbacks).to be_empty
        expect(SidekiqBatchTestAlwaysJob.jobs).to be_empty
        expect(live.reload.callback_fired_at).to be_nil
      end
    end

    describe "when one event's push fails" do
      before do
        allow(SidekiqBatchTestFanInJob).to receive(:perform_async).and_raise(StandardError, "redis down")
      end

      # The claim and the push share a transaction precisely so this holds: an
      # event whose push failed must stay claimable, or the callback is lost and
      # the reaper has nothing to find.
      it "leaves the batch unresolved so the reaper picks it up" do
        batch.fire_callbacks

        expect(batch.reload.callback_fired_at).to be_nil
      end

      it "alerts rather than raising, since the other event still has to go out" do
        expect { batch.fire_callbacks }.not_to raise_error
        expect(alerts.join).to include("##{batch.id}", "`success`", "redis down")
      end

      # The reason each event is claimed on its own. Under a single shared
      # claim the rollback would un-claim the callback that DID go out, and the
      # reaper would re-deliver it on every run until grooming — for as long as
      # the second push kept failing.
      it "does not re-deliver the callback that already went out" do
        batch.fire_callbacks
        Sidekiq::Worker.clear_all

        SidekiqBatch::OrphanedCallbackReaper.call

        expect(SidekiqBatchTestAlwaysJob.jobs).to be_empty
        expect(SidekiqBatchTestFanInJob.jobs).to be_empty
      end

      it "retries only the event that failed, once it can be delivered" do
        batch.fire_callbacks
        Sidekiq::Worker.clear_all
        allow(SidekiqBatchTestFanInJob).to receive(:perform_async).and_call_original

        SidekiqBatch::OrphanedCallbackReaper.call

        expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestAlwaysJob.jobs).to be_empty
        expect(batch.reload.callback_fired_at).to be_present
      end
    end

    # A mistyped class name is resolved before the transaction opens, so it
    # cannot roll back a sibling event that was about to be delivered.
    it "keeps a mistyped callback class from suppressing the other event" do
      batch.update!(callbacks: batch.callbacks.merge("success" => "NoSuchWorkerAnywhere"))

      batch.fire_callbacks

      expect(SidekiqBatchTestAlwaysJob.jobs.size).to eq(1)
      expect(alerts.join).to include("##{batch.id}", "`success`")
      expect(batch.reload.callback_fired_at).to be_nil
    end
  end
end
