# frozen_string_literal: true

require "sidekiq"
require_relative "jobs/version"
require_relative "jobs/engine" if defined?(Rails::Engine)

module Sidekiq
  module Batch
    module Jobs # rubocop:disable Style/Documentation
      class Error < StandardError; end

      class << self
        attr_accessor :auto_install
      end
      self.auto_install = true

      def self.disable_auto_install!
        self.auto_install = false
      end

      # Idempotent — guarded by an installed flag so calling twice (auto-install
      # plus an explicit call in specs, for example) doesn't double-register
      # middleware or death handlers.
      def self.install!
        return if @installed

        ::Sidekiq.configure_client do |config|
          config.client_middleware { |chain| chain.prepend ::SidekiqBatch::ClientMiddleware }
        end

        ::Sidekiq.configure_server do |config|
          config.client_middleware { |chain| chain.prepend ::SidekiqBatch::ClientMiddleware }
          config.server_middleware { |chain| chain.add     ::SidekiqBatch::Middleware }
          config.death_handlers << ->(job, ex) { ::SidekiqBatch::Middleware.handle_death(job, ex) }
        end

        @installed = true
      end

      # For tests: forget that install! has run.
      def self.reset_installed!
        @installed = false
      end
    end
  end
end
