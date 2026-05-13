# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Sidekiq
  module Batch
    module Jobs
      module Generators
        class InstallGenerator < ::Rails::Generators::Base # rubocop:disable Style/Documentation
          include ::Rails::Generators::Migration

          source_root File.expand_path("templates", __dir__)

          def self.next_migration_number(dirname)
            ::ActiveRecord::Generators::Base.next_migration_number(dirname)
          end

          def copy_migration
            migration_template(
              "create_sidekiq_batch_tables.rb.tt",
              "db/migrate/create_sidekiq_batch_tables.rb"
            )
          end
        end
      end
    end
  end
end
