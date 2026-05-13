# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::Batch::Jobs do
  # The engine's `config.after_initialize` ran install! once during Combustion
  # boot — that auto-install fired in client mode (RSpec is not Sidekiq.server?),
  # so the client-middleware side is already wired into the real Sidekiq config.
  #
  # The server side (server_middleware + death handler) only takes effect when
  # `Sidekiq.server?` is true. For those, we stub server? and re-run install!
  # so we can inspect the real configuration.

  describe "client-side auto-install" do
    let(:chain) { Sidekiq.default_configuration.client_middleware }

    it "prepends ClientMiddleware to the client chain (outermost)" do
      entries = chain.entries.map(&:klass)

      expect(entries).to include(SidekiqBatch::ClientMiddleware)
      expect(entries.first).to eq(SidekiqBatch::ClientMiddleware)
    end
  end

  describe "server-side install! (under Sidekiq.server? = true)" do
    before do
      allow(Sidekiq).to receive(:server?).and_return(true)
      described_class.reset_installed!
      described_class.install!
    end

    it "adds server Middleware to the end of the server chain" do
      entries = Sidekiq.default_configuration.server_middleware.entries.map(&:klass)

      expect(entries).to include(SidekiqBatch::Middleware)
      expect(entries.last).to eq(SidekiqBatch::Middleware)
    end

    it "registers a death handler" do
      handlers = Sidekiq.default_configuration.death_handlers

      expect(handlers.any? { |h| h.respond_to?(:call) }).to be(true)
    end
  end

  describe ".install! idempotency" do
    it "does not double-register the client middleware on a second call" do
      described_class.install!

      entries = Sidekiq.default_configuration.client_middleware.entries
      count = entries.count { |e| e.klass == SidekiqBatch::ClientMiddleware }

      expect(count).to eq(1)
    end
  end

  describe ".disable_auto_install!" do
    after { described_class.auto_install = true }

    it "flips the flag" do
      expect { described_class.disable_auto_install! }
        .to change(described_class, :auto_install).from(true).to(false)
    end
  end
end
