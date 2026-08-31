# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "generators/sidekiq/batch/jobs/install/install_generator"

RSpec.describe Sidekiq::Batch::Jobs::Generators::InstallGenerator do
  around do |example|
    Dir.mktmpdir("sidekiq-batch-jobs-generator") do |dir|
      @destination = dir
      example.run
    end
  end

  attr_reader :destination

  def run_generator
    described_class.start(["--quiet"], destination_root: destination)
  end

  def migration_path
    Dir[File.join(destination, "db", "migrate", "*_create_sidekiq_batch_tables.rb")].first
  end

  it "writes exactly one timestamped migration" do
    run_generator

    expect(Dir[File.join(destination, "db", "migrate", "*.rb")].size).to eq(1)
    expect(File.basename(migration_path)).to match(/\A\d{14}_create_sidekiq_batch_tables\.rb\z/)
  end

  describe "the migration version" do
    # A hardcoded version makes the generator unusable on any host running a
    # different Rails: `ActiveRecord::Migration[7.1]` is an unknown migration
    # version on 6.1, and the migration fails to load.
    it "tracks the host app's ActiveRecord" do
      run_generator

      expect(File.read(migration_path))
        .to include("ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]")
    end

    it "leaves no unrendered ERB behind" do
      run_generator

      expect(File.read(migration_path)).not_to include("<%")
    end
  end

  # The template and spec/internal/db/schema.rb are separate files that have to
  # agree. The suite runs against the schema, so anything the template forgets
  # fails nothing here and everything in a host application's first migration.
  it "indexes the columns the maintenance workers filter on" do
    run_generator

    migration = File.read(migration_path)

    # The stuck-job reaper asks which batches have had no job activity lately.
    expect(migration).to include("add_index :sidekiq_batch_jobs, :updated_at")
    # The groomer deletes terminal batches by age, in chunks.
    expect(migration).to include("add_index :sidekiq_batches, [:status, :created_at]")
  end

  # The same drift guard, for the columns rather than the indexes.
  it "creates the columns the completion statement reads" do
    run_generator

    migration = File.read(migration_path)

    expect(migration).to include("t.string   :failure_policy")
    expect(migration).to include("t.integer  :failure_tolerance")
    # Set when a jobs {} block never finished; forces failure whatever the policy.
    expect(migration).to include("t.jsonb    :enrollment_error")
    expect(migration).to include("t.jsonb    :callbacks_fired,   null: false, default: {}")
  end

  it "generates syntactically valid Ruby" do
    run_generator

    expect { RubyVM::InstructionSequence.compile(File.read(migration_path)) }.not_to raise_error
  end

  # Thor turns every public instance method on a generator into a step it
  # invokes. `migration_version` is a helper, not a step — if it is ever made
  # public, Thor will call it as part of the run.
  it "exposes only the migration copy as a generator step" do
    expect(described_class.commands.keys).to eq(["copy_migration"])
  end
end
