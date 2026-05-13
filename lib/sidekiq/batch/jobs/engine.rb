# frozen_string_literal: true

require "rails/engine"

module Sidekiq
  module Batch
    module Jobs
      class Engine < ::Rails::Engine # rubocop:disable Style/Documentation
        engine_name "sidekiq_batch_jobs"

        config.after_initialize do
          Sidekiq::Batch::Jobs.install! if Sidekiq::Batch::Jobs.auto_install
        end
      end
    end
  end
end
