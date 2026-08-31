# frozen_string_literal: true

FactoryBot.define do
  factory :sidekiq_batch do
    description { "test batch" }
    status      { "pending" }
    total_jobs  { 0 }
    callbacks   { {} }

    trait :running do
      status     { "running" }
      total_jobs { 1 }
    end

    # One worker per outcome, and nothing on the always-fires event, so a batch
    # built with this announces exactly once.
    trait :with_callbacks do
      callbacks { { "success" => "SidekiqBatchTestFanInJob", "failure" => "SidekiqBatchTestFailureJob" } }
    end

    # Adds the outcome-agnostic event, so a batch built with this announces
    # twice — the case the per-event claim exists for.
    trait :with_complete_callback do
      callbacks do
        { "complete" => "SidekiqBatchTestAlwaysJob",
          "success"  => "SidekiqBatchTestFanInJob",
          "failure"  => "SidekiqBatchTestFailureJob" }
      end
    end

    # The :with_all_jobs_* traits create their jobs in an after(:create) hook, so
    # total_jobs starts at 0 and is corrected once the rows exist.
    trait :with_all_jobs_pending do
      transient { job_count { 3 } }

      status     { "running" }
      total_jobs { 0 }

      after(:create) do |batch, evaluator|
        create_list(:sidekiq_batch_job, evaluator.job_count, sidekiq_batch: batch)
        batch.update!(total_jobs: evaluator.job_count)
      end
    end

    trait :with_all_jobs_complete do
      transient { job_count { 2 } }

      status     { "running" }
      total_jobs { 0 }

      after(:create) do |batch, evaluator|
        create_list(:sidekiq_batch_job, evaluator.job_count, :complete, sidekiq_batch: batch)
        batch.update!(total_jobs: evaluator.job_count)
      end
    end

    trait :with_all_jobs_failed do
      transient { job_count { 2 } }

      status     { "running" }
      total_jobs { 0 }

      after(:create) do |batch, evaluator|
        create_list(:sidekiq_batch_job, evaluator.job_count, :failed, sidekiq_batch: batch)
        batch.update!(total_jobs: evaluator.job_count)
      end
    end

    # Two of four terminal — exactly 50% progress.
    trait :with_mixed_jobs do
      status     { "running" }
      total_jobs { 4 }

      after(:create) do |batch|
        create(:sidekiq_batch_job, :complete, sidekiq_batch: batch)
        create(:sidekiq_batch_job, :failed,   sidekiq_batch: batch)
        create_list(:sidekiq_batch_job, 2,    sidekiq_batch: batch)
      end
    end
  end
end
