# frozen_string_literal: true

require "spec_helper"

# The failure policy is decided inside the completion UPDATE, so these exercise
# it the only way that proves anything: by running the statement and reading the
# status it returns.
RSpec.describe SidekiqBatch::CompletionQuery do
  def outcome_of(complete:, failed:, **attrs)
    batch = create(:sidekiq_batch, :running, total_jobs: complete + failed, **attrs)

    create_list(:sidekiq_batch_job, complete, :complete, sidekiq_batch: batch) if complete.positive?
    create_list(:sidekiq_batch_job, failed,   :failed,   sidekiq_batch: batch) if failed.positive?

    batch.attempt_completion!
  end

  describe "any_failure, the default" do
    it "succeeds when every job succeeded" do
      expect(outcome_of(complete: 3, failed: 0)).to eq("succeeded")
    end

    it "fails on a single failure among many" do
      expect(outcome_of(complete: 99, failed: 1, failure_policy: :any_failure)).to eq("failed")
    end

    it "is what a batch created without saying anything gets" do
      expect(create(:sidekiq_batch).failure_policy).to eq("any_failure")
    end
  end

  describe "all_failed" do
    it "succeeds while even one job survived" do
      expect(outcome_of(complete: 1, failed: 9, failure_policy: :all_failed)).to eq("succeeded")
    end

    it "fails only when nothing survived" do
      expect(outcome_of(complete: 0, failed: 10, failure_policy: :all_failed)).to eq("failed")
    end

    # The threshold is total_jobs - 1, which without a floor is -1 for an empty
    # batch — and every count, including zero, is greater than -1.
    it "does not fail a batch that has no jobs at all" do
      expect(outcome_of(complete: 0, failed: 0, failure_policy: :all_failed)).to eq("succeeded")
    end

    it "behaves like any_failure for a single-job batch" do
      expect(outcome_of(complete: 0, failed: 1, failure_policy: :all_failed)).to eq("failed")
      expect(outcome_of(complete: 1, failed: 0, failure_policy: :all_failed)).to eq("succeeded")
    end
  end

  describe "tolerate: a number of jobs" do
    it "succeeds at exactly the tolerance" do
      expect(outcome_of(complete: 5, failed: 3, failure_policy: { tolerate: 3 })).to eq("succeeded")
    end

    it "fails one past it" do
      expect(outcome_of(complete: 5, failed: 4, failure_policy: { tolerate: 3 })).to eq("failed")
    end

    it "is any_failure when the tolerance is zero" do
      expect(outcome_of(complete: 5, failed: 1, failure_policy: { tolerate: 0 })).to eq("failed")
    end

    # Documented, and a little surprising: a tolerance wide enough to swallow
    # the whole batch means an all-failed batch still announces success.
    it "succeeds even with everything failed when the tolerance covers it" do
      expect(outcome_of(complete: 0, failed: 2, failure_policy: { tolerate: 5 })).to eq("succeeded")
    end
  end

  describe "tolerate: a percentage" do
    # 5% of 20 is 1.
    it "succeeds at exactly the tolerated share" do
      expect(outcome_of(complete: 19, failed: 1, failure_policy: { tolerate: "5%" })).to eq("succeeded")
    end

    it "fails one past it" do
      expect(outcome_of(complete: 18, failed: 2, failure_policy: { tolerate: "5%" })).to eq("failed")
    end

    # 5% of 4 floors to 0, so a small batch gets no slack at all.
    it "rounds down, so a batch too small to earn any slack tolerates nothing" do
      expect(outcome_of(complete: 3, failed: 1, failure_policy: { tolerate: "5%" })).to eq("failed")
    end

    it "is any_failure at 0%" do
      expect(outcome_of(complete: 9, failed: 1, failure_policy: { tolerate: "0%" })).to eq("failed")
    end

    it "never fails at 100%" do
      expect(outcome_of(complete: 0, failed: 4, failure_policy: { tolerate: "100%" })).to eq("succeeded")
    end
  end

  describe "a row written behind the model's back" do
    # update_all and insert_all skip the writer and the validations, so the
    # statement has to read a missing policy as the strict default rather than
    # letting a NULL decide somebody's outcome.
    it "reads a NULL policy as any_failure" do
      batch = create(:sidekiq_batch, :running, total_jobs: 2)
      SidekiqBatch.where(id: batch.id).update_all(failure_policy: nil)
      create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
      create(:sidekiq_batch_job, :failed,   sidekiq_batch: batch)

      expect(batch.attempt_completion!).to eq("failed")
    end

    it "reads a missing tolerance as zero rather than as unlimited" do
      batch = create(:sidekiq_batch, :running, total_jobs: 2, failure_policy: { tolerate: 5 })
      SidekiqBatch.where(id: batch.id).update_all(failure_tolerance: nil)
      create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
      create(:sidekiq_batch_job, :failed,   sidekiq_batch: batch)

      expect(batch.attempt_completion!).to eq("failed")
    end
  end

  describe "the WHERE clause, which no policy may weaken" do
    it "still refuses to transition while a job is pending" do
      batch = create(:sidekiq_batch, :running, total_jobs: 2, failure_policy: { tolerate: "100%" })
      create(:sidekiq_batch_job, :failed, sidekiq_batch: batch)
      create(:sidekiq_batch_job,          sidekiq_batch: batch)

      expect(batch.attempt_completion!).to be_nil
      expect(batch.reload.status).to eq("running")
    end

    it "still transitions exactly once" do
      batch = create(:sidekiq_batch, :running, total_jobs: 1, failure_policy: :all_failed)
      create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)

      expect(batch.attempt_completion!).to eq("succeeded")
      expect(batch.attempt_completion!).to be_nil
    end
  end
end
