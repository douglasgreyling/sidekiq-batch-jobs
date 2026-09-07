# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Sidekiq
  module Batch
    module Jobs
      module Generators
        # Brings an existing installation up to the schema this version of the
        # gem expects.
        #
        # It reads the host's real tables and emits only what they are missing,
        # rather than shipping one migration per release. A user upgrading from
        # 0.1.0 and a user upgrading from the release before this one run the
        # same command and each get exactly the difference that applies to
        # them, in one migration. Running it on a current database writes
        # nothing at all, so it is safe to run whenever a release mentions the
        # schema, and safe to run twice.
        class UpgradeGenerator < ::Rails::Generators::Base
          include ::Rails::Generators::Migration

          source_root File.expand_path("templates", __dir__)

          desc "Adds whatever the sidekiq-batch-jobs tables are missing for this version of the gem."

          def self.next_migration_number(dirname)
            ::ActiveRecord::Generators::Base.next_migration_number(dirname)
          end

          def copy_migration
            return report_missing_tables if missing_tables.any?
            return report_up_to_date     if changes.empty?

            migration_template("upgrade_sidekiq_batch_tables.rb.tt", "db/migrate/#{migration_basename}.rb")
          end

          # NOTE: must stay private. Thor turns every public instance method on
          # a generator into a step it invokes.
          private

          # Named for the version it upgrades to, so a later release's migration
          # cannot collide with this one: two files called
          # `upgrade_sidekiq_batch_tables` would be a duplicate migration name.
          def migration_basename
            "upgrade_sidekiq_batch_tables_to_v#{::Sidekiq::Batch::Jobs::VERSION.tr(".", "_")}"
          end

          # The template cannot hardcode a version: `ActiveRecord::Migration[7.1]`
          # is unknown on Rails 6.1. Track whatever the host app runs instead.
          def migration_version
            "[#{::ActiveRecord::Migration.current_version}]"
          end

          # Read by the template.
          def migration_body
            changes.map { |line| "    #{line}" }.join("\n")
          end

          def changes
            @changes ||= added_columns + added_indexes + dropped_indexes
          end

          def added_columns
            Schema::COLUMNS.flat_map do |table, columns|
              columns
                .reject { |name, _type, _options| connection.column_exists?(table, name) }
                .map    { |name, type, options| "add_column :#{table}, :#{name}, :#{type}#{arguments(options)}" }
            end
          end

          def added_indexes
            Schema::INDEXES.flat_map do |table, indexes|
              indexes
                .reject { |columns, _options| index?(table, columns) }
                .map    { |columns, options| "add_index :#{table}, #{columns.inspect}#{arguments(options)}" }
            end
          end

          def dropped_indexes
            Schema::SUPERSEDED_INDEXES.flat_map do |table, indexes|
              indexes
                .select { |columns| index?(table, columns) }
                .map    { |columns| "remove_index :#{table}, #{columns.inspect}" }
            end
          end

          # Deliberately unqualified by the index's options. An index on the
          # right columns is what the gem's queries need; rebuilding one a host
          # has already tuned differently is not this generator's business.
          def index?(table, columns)
            connection.index_exists?(table, columns)
          end

          def arguments(options)
            return "" if options.empty?

            ", #{options.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")}"
          end

          def missing_tables
            @missing_tables ||= Schema::TABLES.reject { |table| connection.table_exists?(table) }
          end

          def report_missing_tables
            say_status :skip,
                       "#{missing_tables.join(" and ")} not found. This upgrades an existing installation; " \
                       "run `rails g sidekiq:batch:jobs:install` to create the tables.",
                       :yellow
          end

          def report_up_to_date
            say_status :identical, "the sidekiq-batch-jobs tables are already current", :blue
          end

          # Reported rather than raised as a connection error, since the reason
          # this generator needs a database at all is not obvious from one.
          def connection
            @connection ||= ::ActiveRecord::Base.connection
          rescue ::ActiveRecord::ActiveRecordError => e
            raise ::Rails::Generators::Error,
                  "sidekiq-batch-jobs: this generator compares your schema against the one this version " \
                  "expects, and the database could not be read (#{e.class}: #{e.message})."
          end
        end
      end
    end
  end
end
