# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::Batch::Jobs do
  # Combustion boot already ran install! once, in client mode, so the client
  # chain is wired into the real Sidekiq config. The server side only takes
  # effect when `Sidekiq.server?` is true, so those examples stub it and re-run
  # install! against that same real configuration.

  def chain_entries(chain, klass)
    chain.entries.select { |entry| entry.klass.to_s == klass.to_s }
  end

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
      described_class.install!
    end

    it "adds server Middleware to the end of the server chain" do
      entries = Sidekiq.default_configuration.server_middleware.entries.map(&:klass)

      expect(entries).to include(SidekiqBatch::Middleware)
      expect(entries.last).to eq(SidekiqBatch::Middleware)
    end
  end

  describe "the death handler" do
    let(:handlers) { Sidekiq.default_configuration.death_handlers }

    it "is registered once and stays registered once across repeated installs" do
      expect { 3.times { described_class.install! } }.not_to(change { handlers.size })
      expect(handlers.count(described_class::DEATH_HANDLER)).to eq(1)
    end

    it "dispatches to SidekiqBatch::Middleware when a job dies" do
      job   = { "jid" => "abc" }
      error = StandardError.new("boom")

      # The handler names SidekiqBatch::Middleware inside its body rather than
      # at registration time. That is what lets install! run without autoloading
      # app code, and what makes a reloaded Middleware class get picked up.
      allow(SidekiqBatch::Middleware).to receive(:handle_death)

      described_class::DEATH_HANDLER.call(job, error)

      expect(SidekiqBatch::Middleware).to have_received(:handle_death).with(job, error)
    end
  end

  describe ".install! idempotency" do
    it "does not double-register the client middleware on a second call" do
      described_class.install!

      chain = Sidekiq.default_configuration.client_middleware

      expect(chain_entries(chain, SidekiqBatch::ClientMiddleware).size).to eq(1)
    end
  end

  describe "reload safety" do
    # Stands in for what the reloader does to an autoloaded class: the constant
    # is rebound to a brand new Class object while Sidekiq's chain still holds
    # the old one. Sidekiq de-duplicates on object identity, so a stale entry
    # does not match the new constant and would otherwise survive.
    let(:stale_class) do
      Class.new do
        def self.to_s
          "SidekiqBatch::ClientMiddleware"
        end

        def call(*)
          yield
        end
      end
    end

    it "replaces a same-named entry left behind by a code reload" do
      chain = Sidekiq.default_configuration.client_middleware
      chain.entries.delete_if { |entry| entry.klass.to_s == "SidekiqBatch::ClientMiddleware" }
      chain.prepend(stale_class)

      described_class.install!

      matching = chain_entries(chain, SidekiqBatch::ClientMiddleware)

      expect(matching.size).to eq(1)
      expect(matching.first.klass).to be(SidekiqBatch::ClientMiddleware)
      expect(matching.first.klass).not_to be(stale_class)
    end

    # Driving the real reloader (`Rails.application.reloader.prepare!`) is not
    # viable in this harness: it disconnects the ActiveRecord pool while leaving
    # the adapter checked out, and DatabaseCleaner holds a delegated reference to
    # the now-dead connection, so every later example fails. Re-running the
    # registration is covered by the idempotency example above; that the engine
    # registers through `config.to_prepare` at all is verified against a real app
    # in ROADMAP 1.7.
  end

  describe "auto_install" do
    it "is on by default so the engine wires itself up" do
      expect(described_class.auto_install).to be(true)
    end

    it "can be switched off for hosts that wire middleware themselves" do
      described_class.configure { |config| config.auto_install = false }

      expect(described_class.auto_install).to be(false)
    end
  end
end
