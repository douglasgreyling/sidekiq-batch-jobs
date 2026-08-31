# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::Batch::Jobs::FailurePolicy do
  def normalize(value)
    described_class.normalize(value)
  end

  describe ".normalize" do
    it "accepts the named policies as symbols" do
      expect(normalize(:any_failure)).to have_attributes(name: "any_failure", tolerance: nil)
      expect(normalize(:all_failed)).to  have_attributes(name: "all_failed",  tolerance: nil)
    end

    it "accepts the named policies as strings" do
      expect(normalize("all_failed")).to have_attributes(name: "all_failed", tolerance: nil)
    end

    it "reads a job count as an absolute tolerance" do
      expect(normalize(tolerate: 10)).to have_attributes(name: "tolerate_jobs", tolerance: 10)
    end

    it "reads a percentage as a proportional tolerance" do
      expect(normalize(tolerate: "5%")).to have_attributes(name: "tolerate_percent", tolerance: 5)
    end

    it "ignores whitespace around a percentage" do
      expect(normalize(tolerate: " 5 % ")).to have_attributes(name: "tolerate_percent", tolerance: 5)
    end

    it "accepts a string key, since config files rarely agree on which to use" do
      expect(normalize("tolerate" => 3)).to have_attributes(name: "tolerate_jobs", tolerance: 3)
    end

    it "passes an already-normalised policy straight through" do
      policy = normalize(:all_failed)

      expect(normalize(policy)).to be(policy)
    end

    it "treats a zero tolerance as its own policy rather than rewriting it" do
      expect(normalize(tolerate: 0)).to have_attributes(name: "tolerate_jobs", tolerance: 0)
    end

    # The two tolerate_* names are how the column stores a tolerance, not
    # something to write by hand — they mean nothing without the number.
    it "rejects the internal storage names" do
      expect { normalize(:tolerate_jobs) }.to raise_error(ArgumentError, /unknown failure policy/)
    end

    it "rejects an unknown name" do
      expect { normalize(:mostly_fine) }.to raise_error(ArgumentError, /unknown failure policy/)
    end

    it "rejects a negative job count" do
      expect { normalize(tolerate: -1) }.to raise_error(ArgumentError, /cannot be negative/)
    end

    it "rejects a percentage above 100" do
      expect { normalize(tolerate: "101%") }.to raise_error(ArgumentError, /cannot exceed 100%/)
    end

    # Deliberately strict: "10" could plausibly mean ten jobs or ten percent,
    # and guessing wrong changes when somebody's batch fails.
    it "rejects a bare numeric string, which could mean either unit" do
      expect { normalize(tolerate: "10") }.to raise_error(ArgumentError, /unknown failure policy/)
    end

    it "rejects a hash that does not name a tolerance" do
      expect { normalize(threshold: 10) }.to raise_error(ArgumentError, /unknown failure policy/)
    end

    it "rejects extra keys rather than silently dropping a typo" do
      expect { normalize(tolerate: 10, of: :jobs) }.to raise_error(ArgumentError, /unknown failure policy/)
    end

    it "rejects anything else" do
      expect { normalize(nil) }.to raise_error(ArgumentError, /unknown failure policy/)
      expect { normalize(10) }.to  raise_error(ArgumentError, /unknown failure policy/)
    end
  end

  # spec/support/configuration.rb snapshots the config object with a shallow
  # `dup`, so a mutable default would be shared between examples and leak.
  it "is frozen, so the configured default cannot be mutated in place" do
    expect(normalize(:any_failure)).to be_frozen
  end

  it "compares by value" do
    expect(normalize(tolerate: 10)).to eq(normalize(tolerate: 10))
    expect(normalize(tolerate: 10)).not_to eq(normalize(tolerate: 11))
    expect(normalize(tolerate: 10)).not_to eq(normalize(tolerate: "10%"))
  end

  it "renders the columns it maps onto" do
    expect(normalize(tolerate: "5%").to_h)
      .to eq(failure_policy: "tolerate_percent", failure_tolerance: 5)
  end
end
