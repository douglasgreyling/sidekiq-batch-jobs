# frozen_string_literal: true

module Sidekiq
  module Batch
    module Jobs
      # ActiveRecord's `enum` signature moved twice inside the range this gem
      # supports, and no single call works across all of it:
      #
      #   6.1      def enum(definitions)                       hash only, `_suffix:`
      #   7.0-7.2  def enum(name = nil, values = nil, **opts)  either form
      #   8.0      def enum(name, values = nil, **opts)        positional, `suffix:`
      #
      # So 6.1 rejects the modern call and 8.0 rejects the legacy one. Both forms
      # generate an identical surface (`.statuses`, the `pending_status?`
      # predicates, the `pending_status` scopes), so which branch a given Rails
      # takes is invisible to everything downstream.
      module EnumCompat
        # @param values [Hash{Symbol => Integer}] status name => column value
        def status_enum(values)
          if ::ActiveRecord::VERSION::MAJOR >= 7
            enum :status, values, suffix: :status
          else
            enum status: values, _suffix: :status
          end
        end
      end
    end
  end
end
