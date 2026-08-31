# frozen_string_literal: true

module Sidekiq
  module Batch
    module Jobs
      # Everything a host can tune, through `Sidekiq::Batch::Jobs.configure`. An
      # initializer is the right place: it runs before any model is autoloaded,
      # which `base_class_name` requires.
      class Configuration
        DEFAULT_BASE_CLASS_NAME   = "ActiveRecord::Base"
        DEFAULT_STUCK_AFTER       = 2 * 60 * 60       # 2 hours
        DEFAULT_RETENTION         = 30 * 24 * 60 * 60 # 30 days
        DEFAULT_ERROR_MESSAGE_MAX = 4_000
        DEFAULT_MAINTENANCE_QUEUE = "default"
        DEFAULT_FAILURE_POLICY    = :any_failure

        # Warn rather than stay silent: the reaper only speaks up after it has
        # marked someone's jobs failed or re-fired a callback. Never routine.
        DEFAULT_ON_ALERT = ->(message) { ::Sidekiq.logger.warn("[sidekiq-batch-jobs] #{message}") }

        attr_accessor :auto_install, :maintenance_queue

        # In characters, not bytes.
        attr_accessor :error_message_max

        # Callable taking one String, or nil to silence entirely.
        attr_accessor :on_alert

        attr_reader :base_class_name, :stuck_after, :retention, :failure_policy

        def initialize
          @auto_install      = true
          @base_class_name   = DEFAULT_BASE_CLASS_NAME
          @stuck_after       = DEFAULT_STUCK_AFTER
          @retention         = DEFAULT_RETENTION
          @error_message_max = DEFAULT_ERROR_MESSAGE_MAX
          @maintenance_queue = DEFAULT_MAINTENANCE_QUEUE
          @on_alert          = DEFAULT_ON_ALERT
          @failure_policy    = FailurePolicy.normalize(DEFAULT_FAILURE_POLICY)
        end

        # A name, not a Class: resolving a constant at configuration time would
        # autoload application code during initialization, and a stored Class
        # goes stale the moment the reloader swaps it out. A Class is accepted,
        # but kept by name for the same reason.
        def base_class_name=(value)
          @base_class_name = value.to_s
        end

        # Never memoised, so each reload of the models picks up the current
        # object. `const_get` rather than `constantize` because this runs from a
        # model class body, where ActiveSupport may not be loaded yet.
        def base_class
          ::Object.const_get(base_class_name)
        end

        # Keep comfortably longer than Sidekiq's ~30s heartbeat expiry, so the
        # reaper never races Sidekiq's own recovery of a crashed process's jobs.
        def stuck_after=(value)
          @stuck_after = coerce_seconds(value, :stuck_after)
        end

        def retention=(value)
          @retention = coerce_seconds(value, :retention)
        end

        # Normalised here rather than at completion time, so a typo raises while
        # the initializer runs instead of hours later inside the one statement
        # that decides a batch's outcome. See FailurePolicy for the forms.
        def failure_policy=(value)
          @failure_policy = FailurePolicy.normalize(value)
        end

        # A broken alert channel must not take down the reaper run that was
        # trying to report through it.
        def alert(message)
          on_alert&.call(message)
        rescue StandardError => e
          ::Sidekiq.logger.error(
            "[sidekiq-batch-jobs] on_alert raised #{e.class}: #{e.message} — original message: #{message}"
          )
        end

        private

        # Duration is not a Numeric subclass, but it overrides `is_a?` to answer
        # for the value it wraps, so one check covers both and still rejects
        # strings.
        def coerce_seconds(value, name)
          unless value.is_a?(Numeric)
            raise ArgumentError,
                  "#{name} must be a number of seconds or an ActiveSupport::Duration, got #{value.inspect}"
          end

          value.to_i
        end
      end
    end
  end
end
