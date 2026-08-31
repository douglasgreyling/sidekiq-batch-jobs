# frozen_string_literal: true

require "rails/engine"

module Sidekiq
  module Batch
    module Jobs
      class Engine < ::Rails::Engine
        engine_name "sidekiq_batch_jobs"

        # `to_prepare`, not `after_initialize`: install! names autoloadable app
        # code, and referencing that during initialization is deprecated on
        # Rails 6.1 and leaves Sidekiq's chain holding classes the reloader later
        # unloads. to_prepare runs after boot and again on every reload.
        config.to_prepare do
          Sidekiq::Batch::Jobs.install! if Sidekiq::Batch::Jobs.auto_install
        end
      end
    end
  end
end
