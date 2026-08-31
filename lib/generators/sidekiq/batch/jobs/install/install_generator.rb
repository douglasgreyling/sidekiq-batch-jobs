# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Sidekiq
  module Batch
    module Jobs
      module Generators
        class InstallGenerator < ::Rails::Generators::Base
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

          # NOTE: must stay private. Thor turns every public instance method on
          # a generator into a step it invokes.
          private

          # The template cannot hardcode a version: `ActiveRecord::Migration[7.1]`
          # is unknown on Rails 6.1. Track whatever the host app runs instead.
          def migration_version
            "[#{::ActiveRecord::Migration.current_version}]"
          end
        end
      end
    end
  end
end
