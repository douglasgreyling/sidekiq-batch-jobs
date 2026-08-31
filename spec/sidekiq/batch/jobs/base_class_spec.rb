# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Sidekiq::Batch::Jobs.base_class" do
  subject(:config) { Sidekiq::Batch::Jobs.config }

  # spec/support/configuration.rb restores the whole config object around every
  # example, so these can mutate it freely. The dummy app runs on a non-default
  # base class, which is what makes the inheritance example below meaningful;
  # see spec/internal/app/models/sidekiq_batch_jobs_test_record.rb.

  # Anonymous abstract classes stand in for a host's ApplicationRecord without
  # needing a table. stub_const is safe here: these names are invented by the
  # spec, so nothing Zeitwerk manages is touched.
  def abstract_record
    Class.new(ActiveRecord::Base) { self.abstract_class = true }
  end

  it "ships with ActiveRecord::Base as the default" do
    fresh = Sidekiq::Batch::Jobs::Configuration.new

    expect(fresh.base_class_name).to eq("ActiveRecord::Base")
    expect(fresh.base_class).to be(ActiveRecord::Base)
  end

  it "resolves a namespaced name" do
    stub_const("SidekiqBatchJobsSpec::Base", abstract_record)

    config.base_class_name = "SidekiqBatchJobsSpec::Base"

    expect(config.base_class).to be(SidekiqBatchJobsSpec::Base)
  end

  it "stores a class by name rather than holding the object" do
    config.base_class_name = ActiveRecord::Base

    expect(config.base_class_name).to eq("ActiveRecord::Base")
  end

  # The property that makes the hook reload-safe: after a reload the constant
  # points at a brand new Class object, and a memoised resolution would leave the
  # models hanging off a class the reloader has already discarded.
  it "re-resolves on every call rather than memoising" do
    first  = abstract_record
    second = abstract_record

    stub_const("SidekiqBatchJobsSpecBase", first)
    config.base_class_name = "SidekiqBatchJobsSpecBase"
    expect(config.base_class).to be(first)

    stub_const("SidekiqBatchJobsSpecBase", second)
    expect(config.base_class).to be(second)
  end

  it "raises a clear error when the configured name does not exist" do
    config.base_class_name = "NoSuchBaseClass"

    expect { config.base_class }.to raise_error(NameError, /NoSuchBaseClass/)
  end

  describe "configured from a Rails initializer" do
    it "takes effect before the models are autoloaded" do
      expect(config.base_class_name).to eq("SidekiqBatchJobsTestRecord")
    end

    it "is the class both models inherit from" do
      expect(SidekiqBatch.superclass).to be(SidekiqBatchJobsTestRecord)
      expect(SidekiqBatchJob.superclass).to be(SidekiqBatchJobsTestRecord)
    end
  end
end
