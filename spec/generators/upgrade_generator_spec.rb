# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "generators/sidekiq/batch/jobs/upgrade/upgrade_generator"

RSpec.describe Sidekiq::Batch::Jobs::Generators::UpgradeGenerator do
  around do |example|
    Dir.mktmpdir("sidekiq-batch-jobs-upgrade") do |dir|
      @destination = dir
      example.run
    end
  ensure
    # These examples take the real schema apart to give the generator something
    # to find. Rebuild it from spec/internal/db/schema.rb rather than undoing
    # each change by hand, so a failing example cannot leave the suite behind a
    # half-dropped table.
    restore_schema
  end

  attr_reader :destination

  def restore_schema
    connection = ActiveRecord::Base.connection

    # Ahead of the load because schema.rb creates with `force: true`, and
    # Postgres will not drop sidekiq_batches while the jobs table's foreign key
    # still points at it. Children first, and the constraint goes with them.
    connection.drop_table :sidekiq_batch_jobs, if_exists: true
    connection.drop_table :sidekiq_batches,    if_exists: true

    ActiveRecord::Migration.suppress_messages { load Rails.root.join("db", "schema.rb") }

    SidekiqBatch.reset_column_information
    SidekiqBatchJob.reset_column_information
  end

  def run_generator
    described_class.start(["--quiet"], destination_root: destination)
  end

  def migration
    path = Dir[File.join(destination, "db", "migrate", "*.rb")].first

    path && File.read(path)
  end

  # Doubles as the drift guard between Sidekiq::Batch::Jobs::Schema and the
  # tables the suite actually runs against: anything the module claims that
  # spec/internal/db/schema.rb does not create shows up here as a stray
  # add_column, and install_generator_spec holds that schema to the install
  # template in turn.
  it "writes nothing against a database that is already current" do
    run_generator

    expect(migration).to be_nil
  end

  it "adds only the columns the database is missing" do
    ActiveRecord::Base.connection.remove_column :sidekiq_batches, :complete_count
    ActiveRecord::Base.connection.remove_column :sidekiq_batches, :failed_count

    run_generator

    expect(migration).to include("add_column :sidekiq_batches, :complete_count, :integer")
    expect(migration).to include("add_column :sidekiq_batches, :failed_count, :integer")
    # Everything else is present, so nothing else is touched.
    expect(migration).not_to include(":total_jobs")
    expect(migration).not_to include("add_index")
  end

  it "carries the options a column needs rather than adding a bare one" do
    ActiveRecord::Base.connection.remove_column :sidekiq_batches, :callbacks_fired

    run_generator

    expect(migration)
      .to include("add_column :sidekiq_batches, :callbacks_fired, :jsonb, null: false, default: {}")
  end

  it "adds a missing index" do
    ActiveRecord::Base.connection.remove_index :sidekiq_batch_jobs, :updated_at

    run_generator

    expect(migration).to include("add_index :sidekiq_batch_jobs, [:updated_at]")
  end

  # The one on a 0.1.0 schema. Both composites lead with `status`, so Postgres
  # serves a status-only lookup from either and the bare index is dead weight.
  it "drops an index a later version superseded" do
    ActiveRecord::Base.connection.add_index :sidekiq_batches, :status

    run_generator

    expect(migration).to include("remove_index :sidekiq_batches, [:status]")
  end

  it "collects every difference into one migration" do
    ActiveRecord::Base.connection.remove_column :sidekiq_batches, :failed_count
    ActiveRecord::Base.connection.remove_index  :sidekiq_batch_jobs, :updated_at
    ActiveRecord::Base.connection.add_index     :sidekiq_batches, :status

    run_generator

    expect(Dir[File.join(destination, "db", "migrate", "*.rb")].size).to eq(1)
    expect(migration).to include("add_column :sidekiq_batches, :failed_count, :integer")
    expect(migration).to include("add_index :sidekiq_batch_jobs, [:updated_at]")
    expect(migration).to include("remove_index :sidekiq_batches, [:status]")
  end

  it "refuses to guess at a database that has no tables yet" do
    ActiveRecord::Base.connection.drop_table :sidekiq_batch_jobs
    ActiveRecord::Base.connection.drop_table :sidekiq_batches

    run_generator

    expect(migration).to be_nil
  end

  describe "the migration it writes" do
    before { ActiveRecord::Base.connection.remove_column :sidekiq_batches, :complete_count }

    # A hardcoded version makes the generator unusable on any host running a
    # different Rails, exactly as it would in the install generator.
    it "tracks the host app's ActiveRecord" do
      run_generator

      expect(migration).to include("ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]")
    end

    # Two releases that both touch the schema would otherwise write two files
    # called `upgrade_sidekiq_batch_tables`, which Rails rejects as a duplicate
    # migration name.
    it "names itself for the version it upgrades to" do
      run_generator

      slug = Sidekiq::Batch::Jobs::VERSION.tr(".", "_")

      expect(Dir[File.join(destination, "db", "migrate", "*.rb")].first)
        .to match(%r{\A.*/\d{14}_upgrade_sidekiq_batch_tables_to_v#{slug}\.rb\z})
    end

    it "declares a class name matching that file" do
      run_generator

      expect(migration).to match(/class UpgradeSidekiqBatchTablesToV\d+ < ActiveRecord::Migration/)
    end

    it "leaves no unrendered ERB behind" do
      run_generator

      expect(migration).not_to include("<%")
    end

    it "generates syntactically valid Ruby" do
      run_generator

      expect { RubyVM::InstructionSequence.compile(migration) }.not_to raise_error
    end
  end

  # Thor turns every public instance method on a generator into a step it
  # invokes, so a helper that slips out of the private section becomes a step.
  it "exposes only the migration copy as a generator step" do
    expect(described_class.commands.keys).to eq(["copy_migration"])
  end
end
