# frozen_string_literal: true

# Counts the SQL a block actually issues.
#
# The server middleware wraps every job in the host application, so "an
# untracked job touches the database zero times" is a real behavioural claim
# rather than a micro-optimisation — and the only honest way to assert it is to
# count. Schema reflection and transaction bookkeeping are excluded; they are
# noise from ActiveRecord rather than work the code asked for.
module QueryCounter
  IGNORED = %w[SCHEMA TRANSACTION].freeze

  def count_queries(&block)
    queries_made(&block).size
  end

  def queries_made
    queries = []

    subscriber = ::ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] unless IGNORED.include?(payload[:name])
    end

    yield

    queries
  ensure
    ::ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

RSpec.configure do |config|
  config.include QueryCounter
end
