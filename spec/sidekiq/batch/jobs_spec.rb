# frozen_string_literal: true

RSpec.describe Sidekiq::Batch::Jobs do
  it "has a version number" do
    expect(Sidekiq::Batch::Jobs::VERSION).not_to be nil
  end
end
