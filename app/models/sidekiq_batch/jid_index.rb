# frozen_string_literal: true

require "set"
require "sidekiq/api"

class SidekiqBatch
  class JidIndex
    # The dead set is deliberately absent: a job in it will never run again, so
    # counting it as live only hides rows that need reaping. It is what made
    # "Kill All" on the Retries page stall a batch permanently — that button
    # moves jobs to the dead set with `notify_failure: false`, so no death
    # handler runs and nothing marks the rows failed. A reaper that read the
    # dead set as live then skipped them on every run until Redis expired them,
    # six months later by default.
    SORTED_SETS = [::Sidekiq::RetrySet, ::Sidekiq::ScheduledSet].freeze

    def self.call
      jids = Set.new

      add_queued(jids)
      add_sorted_sets(jids)
      add_executing(jids)

      jids
    end

    def self.add_queued(jids)
      ::Sidekiq::Queue.all.each { |queue| queue.each { |job| jids << job.jid } }
    end
    private_class_method :add_queued

    def self.add_sorted_sets(jids)
      SORTED_SETS.each { |set| set.new.each { |job| jids << job.jid } }
    end
    private_class_method :add_sorted_sets

    def self.add_executing(jids)
      # `Sidekiq::Work` is a class, not a Hash — `#payload` is the supported
      # accessor. Hash-style access still works through method_missing, but
      # Sidekiq deprecated it.
      ::Sidekiq::Workers.new.each do |_process_id, _thread_id, work|
        jid = work.payload["jid"]

        jids << jid if jid
      end
    end
    private_class_method :add_executing
  end
end
