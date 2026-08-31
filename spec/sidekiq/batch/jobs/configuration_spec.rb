# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::Batch::Jobs::Configuration do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "wires itself up at boot" do
      expect(config.auto_install).to be(true)
    end

    it "waits two hours before treating a quiet batch as stuck" do
      expect(config.stuck_after).to eq(2 * 60 * 60)
    end

    it "keeps terminal batches for thirty days" do
      expect(config.retention).to eq(30 * 24 * 60 * 60)
    end

    it "truncates stored error messages at 4000 characters" do
      expect(config.error_message_max).to eq(4_000)
    end

    it "runs maintenance on the default queue" do
      expect(config.maintenance_queue).to eq("default")
    end

    it "treats any single failure as a batch failure" do
      expect(config.failure_policy).to eq(Sidekiq::Batch::Jobs::FailurePolicy.normalize(:any_failure))
    end
  end

  describe "#failure_policy=" do
    it "normalises whatever form the host wrote" do
      config.failure_policy = { tolerate: "5%" }

      expect(config.failure_policy).to have_attributes(name: "tolerate_percent", tolerance: 5)
    end

    # Normalised on assignment rather than at completion time, so a typo in an
    # initializer surfaces at boot instead of hours later, inside the one
    # statement that decides a batch's outcome.
    it "rejects a bad policy while the initializer is still running" do
      expect { config.failure_policy = :mostly_fine }
        .to raise_error(ArgumentError, /unknown failure policy/)
    end
  end

  describe "durations" do
    # Accepting both forms matters: hosts will reach for 30.minutes, but the
    # defaults cannot use ActiveSupport at gem-load time, so they are plain
    # integers. Both have to work.
    it "accepts a plain number of seconds" do
      config.stuck_after = 900

      expect(config.stuck_after).to eq(900)
    end

    it "accepts an ActiveSupport::Duration" do
      config.stuck_after = 30.minutes
      config.retention   = 90.days

      expect(config.stuck_after).to eq(1_800)
      expect(config.retention).to eq(7_776_000)
    end

    it "rejects a value that is not a number of seconds" do
      expect { config.retention = "90 days" }
        .to raise_error(ArgumentError, /retention must be a number of seconds/)
    end
  end

  describe "#alert" do
    it "hands the message to the configured callable" do
      seen            = []
      config.on_alert = ->(message) { seen << message }

      config.alert("something happened")

      expect(seen).to eq(["something happened"])
    end

    it "is silent when no callable is configured" do
      config.on_alert = nil

      expect { config.alert("ignored") }.not_to raise_error
    end

    it "warns through the Sidekiq logger by default" do
      # The reaper only speaks after marking somebody's jobs failed, so the
      # default must not be silence.
      expect(Sidekiq.logger).to receive(:warn).with(/marked 3 jobs failed/)

      config.alert("marked 3 jobs failed")
    end
  end

  describe "Sidekiq::Batch::Jobs.configure" do
    it "yields the live config and returns it" do
      returned = Sidekiq::Batch::Jobs.configure { |c| c.retention = 1.day }

      expect(returned).to be(Sidekiq::Batch::Jobs.config)
      expect(Sidekiq::Batch::Jobs.config.retention).to eq(86_400)
    end
  end
end
