# frozen_string_literal: true

FactoryBot.define do
  factory :sidekiq_batch_job do
    sidekiq_batch
    sequence(:jid) { |n| format("%024x", n) }
    worker_class   { "TestWorker" }
    args           { [] }
    status         { "pending" }

    trait :complete do
      status { "complete" }
    end

    trait :failed do
      status        { "failed" }
      error_class   { "RuntimeError" }
      error_message { "boom" }
    end
  end
end
