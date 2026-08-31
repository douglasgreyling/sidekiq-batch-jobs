# frozen_string_literal: true

require "sidekiq"
require_relative "jobs/version"
require_relative "jobs/enum_compat"
require_relative "jobs/failure_policy"
require_relative "jobs/configuration"
require_relative "jobs/engine" if defined?(Rails::Engine)

module Sidekiq
  module Batch
    module Jobs
      class Error < StandardError; end

      # Reconciles jobs that died without re-entering the server middleware
      # (SIGKILL, OOM, pod eviction). A constant, not an inline lambda: the body
      # names SidekiqBatch only when a job dies, so registering never autoloads
      # app code, and one stable identity lets us register it exactly once.
      DEATH_HANDLER = ->(job, error) { ::SidekiqBatch::Middleware.handle_death(job, error) }

      class << self
        attr_writer :config
      end

      def self.config
        @config ||= Configuration.new
      end

      # Host entry point. See Configuration for the full set of knobs.
      def self.configure
        yield config

        config
      end

      # Convenience readers for the two settings read where the extra `.config`
      # hop is noise: a model's class body and the engine's to_prepare hook.
      def self.base_class
        config.base_class
      end

      def self.auto_install
        config.auto_install
      end

      # Safe to call repeatedly. The engine calls it from `config.to_prepare`,
      # which runs at boot and again after every code reload.
      #
      # Deliberately not `Sidekiq.configure_client` / `configure_server`:
      # `configure_server` appends its block to Sidekiq's `@config_blocks`, which
      # `configure_embed` later replays, so calling it once per reload would grow
      # that list without bound.
      def self.install!
        sidekiq_config = ::Sidekiq.default_configuration

        register_death_handler(sidekiq_config)

        # Outermost on the client chain, so dedupe/suppression middleware added
        # later with `chain.add` has the final say on whether a push happens: we
        # enroll only jobs the rest of the chain agrees to push. A server process
        # has its own client chain, so this covers both.
        sidekiq_config.client_middleware { |chain| rebind(chain, ::SidekiqBatch::ClientMiddleware, :prepend) }

        return unless ::Sidekiq.server?

        # `add`, not `prepend`, so this runs LAST in the server chain, outside
        # Sidekiq's retry middleware, and sees each attempt's final disposition.
        sidekiq_config.server_middleware { |chain| rebind(chain, ::SidekiqBatch::Middleware, :add) }
      end

      # Chain#add / #prepend de-duplicate on object identity, so after a reload
      # the constant is a brand new Class, the stale entry does not match, and
      # the middleware runs twice: the second time against a class the reloader
      # has already unloaded. Match on the name instead.
      def self.rebind(chain, klass, position)
        chain.entries.delete_if { |entry| entry.klass.to_s == klass.to_s }
        chain.public_send(position, klass)
      end
      private_class_method :rebind

      def self.register_death_handler(sidekiq_config)
        return if sidekiq_config.death_handlers.include?(DEATH_HANDLER)

        sidekiq_config.death_handlers << DEATH_HANDLER
      end
      private_class_method :register_death_handler
    end
  end
end
