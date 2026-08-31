# frozen_string_literal: true

# A Rails initializer is the supported place to configure the gem: it runs before
# any model is autoloaded, which base_class_name requires, and naming the class as
# a String means nothing is autoloaded during initialization.
Sidekiq::Batch::Jobs.configure do |config|
  config.base_class_name = "SidekiqBatchJobsTestRecord"
end
