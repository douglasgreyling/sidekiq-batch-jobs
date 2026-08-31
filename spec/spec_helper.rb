# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

# concurrent-ruby 1.3.5 dropped its implicit `require "logger"`, which Rails
# < 7.1 relied on. Without this, booting Rails 6.1 dies on `uninitialized
# constant ActiveSupport::LoggerThreadSafeLevel::Logger`. Drop it once the
# minimum supported Rails is 7.1.
require "logger"

require "combustion"

Combustion.path = "spec/internal"
Combustion.initialize! :active_record do
  config.load_defaults Rails::VERSION::STRING.to_f
end

require "rspec/rails"
require "sidekiq/batch/jobs"
require "rspec-sidekiq"
require "database_cleaner/active_record"
require "factory_bot"
require "shoulda/matchers"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include FactoryBot::Syntax::Methods
  # travel_to, for the throughput-based #eta examples.
  config.include ActiveSupport::Testing::TimeHelpers

  # Use deletion (not the AR transactional wrapper) so the multi-thread
  # concurrency spec works — worker threads have their own connections and
  # cannot see uncommitted data from a fixture transaction. Deletion is a
  # bit slower than `:transaction` but the suite is small.
  config.before(:suite) do
    FactoryBot.find_definitions
    DatabaseCleaner.allow_remote_database_url = true
    DatabaseCleaner.strategy                  = :deletion
    DatabaseCleaner.clean_with(:deletion)
  end

  config.around do |example|
    DatabaseCleaner.cleaning { example.run }
  end
end
