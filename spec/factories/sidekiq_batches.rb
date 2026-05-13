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

    trait :with_callbacks do
      callbacks { { "complete" => "SidekiqBatchTestFanInJob", "failure" => "SidekiqBatchTestFailureJob" } }
    end
  end
end
