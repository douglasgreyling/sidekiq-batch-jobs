# frozen_string_literal: true

require "spec_helper"

# H2's other half. BatchEnrollmentContext rescues an ordinary exception and
# starts the batch itself; a SIGKILL runs no rescue, and what it leaves behind
# is a `pending` batch with committed rows whose jobs are already queued —
# the one status neither other reaper nor the groomer looks at.
RSpec.describe SidekiqBatch::AbandonedEnrollmentReaper do
  # Created and enrolled long enough ago to be past `stuck_after`, then left.
  def abandoned(job_count: 2, status: "pending", **attrs)
    travel_to(3.hours.ago) do
      batch = create(:sidekiq_batch, status: status, **attrs)
      create_list(:sidekiq_batch_job, job_count, sidekiq_batch: batch)
      batch
    end
  end

  it "starts an abandoned batch so its queued jobs are tracked again" do
    batch = abandoned

    described_class.call

    expect(batch.reload).to have_attributes(status: "running", total_jobs: 2)
  end

  it "records why it was started by a reaper rather than by its own block" do
    batch = abandoned

    described_class.call

    expect(batch.reload.enrollment_error).to include(
      "class"   => "SidekiqBatch::AbandonedEnrollmentError",
      "message" => a_string_matching(/never finished enrolling/)
    )
  end

  it "reports what it started" do
    batch = abandoned(job_count: 3)

    results = described_class.call

    expect(results.size).to eq(1)
    expect(results.first).to have_attributes(batch: batch, total_jobs: 3)
  end

  # An enrollment that never completed cannot have queued everything it was
  # asked to, so no tolerance covers it.
  it "lands failed once the queued jobs finish, however tolerant the policy" do
    batch = abandoned(job_count: 1, failure_policy: { tolerate: "100%" })

    described_class.call
    batch.sidekiq_batch_jobs.each(&:mark_complete!)
    batch.reload.attempt_completion!

    expect(batch.reload.status).to eq("failed")
  end

  it "fires the failure callback, so the stall is finally announced" do
    batch = abandoned(job_count: 1)
    batch.update!(callbacks: { "failure" => "SidekiqBatchTestFailureJob" })

    described_class.call
    batch.sidekiq_batch_jobs.each(&:mark_complete!)
    batch.reload.attempt_completion!

    expect(SidekiqBatchTestFailureJob.jobs.size).to eq(1)
  end

  # A block working through a large enrolment writes rows constantly, so it is
  # never mistaken for one that died.
  it "leaves a batch whose enrollment is still writing rows alone" do
    batch = abandoned
    batch.sidekiq_batch_jobs.first.touch

    expect(described_class.call).to be_empty
    expect(batch.reload.status).to eq("pending")
  end

  # A batch with no rows yet trivially passes the "no recent job activity"
  # test, so without the age check a brand-new batch would be adopted out from
  # under its own block.
  it "leaves a recently created batch alone" do
    batch = create(:sidekiq_batch)
    create(:sidekiq_batch_job, sidekiq_batch: batch)

    expect(described_class.call).to be_empty
    expect(batch.reload.status).to eq("pending")
  end

  it "leaves a batch that never enrolled anything to the groomer" do
    travel_to(3.hours.ago) { create(:sidekiq_batch) }

    expect(described_class.call).to be_empty
  end

  it "ignores batches that are already running" do
    abandoned(status: "running")

    expect(described_class.call).to be_empty
  end

  it "is safe to run twice" do
    abandoned

    described_class.call

    expect(described_class.call).to be_empty
  end

  # One batch failing must not end the run — every other stalled batch in the
  # system is still waiting.
  it "skips and alerts a batch it cannot start, and carries on" do
    poison  = abandoned
    healthy = abandoned
    alerts  = []

    Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(message) { alerts << message } }
    allow_any_instance_of(SidekiqBatch).to receive(:attempt_completion!) do |batch|
      raise ActiveRecord::StatementInvalid, "pg gone" if batch.id == poison.id
    end

    results = described_class.call

    expect(results.map(&:batch)).to eq([healthy])
    expect(alerts.join).to include("##{poison.id}", "pg gone")
  end
end
