# frozen_string_literal: true

module Sidekiq
  module Batch
    module Jobs
      # What it takes for a batch to count as failed. All four policies are the
      # same rule with a different threshold: the batch fails when more jobs
      # failed than it tolerates.
      #
      #   :any_failure        0                            (the default)
      #   :all_failed         total_jobs - 1
      #   { tolerate: 10 }    10
      #   { tolerate: "5%" }  floor(total_jobs * 5 / 100)
      #
      # Only the name and the number live here; CompletionQuery resolves the
      # threshold in SQL, because `total_jobs` is unknown until the batch starts
      # and the comparison has to stay inside the one atomic transition.
      #
      # Plain Ruby on purpose: Configuration holds one of these and is read from
      # an initializer, where ActiveSupport may not be loaded. So no `blank?`,
      # no `present?`, nothing from ActiveSupport.
      class FailurePolicy
        ANY_FAILURE      = "any_failure"
        ALL_FAILED       = "all_failed"
        TOLERATE_JOBS    = "tolerate_jobs"
        TOLERATE_PERCENT = "tolerate_percent"

        NAMES = [ANY_FAILURE, ALL_FAILED, TOLERATE_JOBS, TOLERATE_PERCENT].freeze

        # Names a user may pass directly. The two `tolerate_*` names are how the
        # column stores a tolerance; they mean nothing without a number beside
        # them, so they are not accepted as input.
        DECLARABLE = [ANY_FAILURE, ALL_FAILED].freeze

        PERCENTAGE = /\A\s*(\d+)\s*%\s*\z/

        MAX_PERCENT = 100

        attr_reader :name, :tolerance

        class << self
          # Coerces whatever a caller supplied into a policy.
          #
          # @param value [Symbol, String, Hash, FailurePolicy]
          # @return [FailurePolicy] frozen
          # @raise [ArgumentError] on anything it cannot make sense of
          def normalize(value)
            case value
            when FailurePolicy   then value
            when Symbol, String  then named(value.to_s)
            when Hash            then tolerant(value)
            else reject(value)
            end
          end

          private

          def named(name)
            reject(name) unless DECLARABLE.include?(name)

            new(name: name, tolerance: nil)
          end

          def tolerant(hash)
            keys = hash.keys.map(&:to_s)

            reject(hash) unless keys == ["tolerate"]

            amount = hash[:tolerate].nil? ? hash["tolerate"] : hash[:tolerate]

            case amount
            when Integer then jobs(amount)
            when String  then percent(amount)
            else reject(hash)
            end
          end

          def jobs(count)
            raise ArgumentError, "failure policy tolerate: #{count} cannot be negative" if count.negative?

            new(name: TOLERATE_JOBS, tolerance: count)
          end

          def percent(string)
            match = PERCENTAGE.match(string)

            reject(string) unless match

            value = match[1].to_i

            raise ArgumentError, "failure policy tolerate: #{string.inspect} cannot exceed 100%" if value > MAX_PERCENT

            new(name: TOLERATE_PERCENT, tolerance: value)
          end

          def reject(value)
            raise ArgumentError,
                  "unknown failure policy #{value.inspect} — expected :any_failure, :all_failed, " \
                  "{ tolerate: <count> } or { tolerate: \"<n>%\" }"
          end
        end

        def initialize(name:, tolerance:)
          @name      = name
          @tolerance = tolerance

          freeze
        end

        def ==(other)
          other.is_a?(FailurePolicy) && other.name == name && other.tolerance == tolerance
        end
        alias eql? ==

        def hash
          [name, tolerance].hash
        end

        def to_h
          { failure_policy: name, failure_tolerance: tolerance }
        end

        def inspect
          tolerance.nil? ? "#<FailurePolicy #{name}>" : "#<FailurePolicy #{name} #{tolerance}>"
        end
      end
    end
  end
end
