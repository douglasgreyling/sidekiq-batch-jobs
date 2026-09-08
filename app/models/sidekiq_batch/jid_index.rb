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

    # Two shapes to survive here, and reading either one naively is silently
    # wrong rather than loud.
    #
    # `payload` holds the job as a JSON *string*, not a nested object: the
    # processor stores `{queue:, payload: jobstr, run_at:}`. So `payload["jid"]`
    # is String indexing, which finds the key *name* in the JSON and returns the
    # literal "jid" for every job on the cluster. The index fills with one
    # constant, no executing job is ever found in it, and StuckJobReaper fails
    # rows whose jobs are running perfectly well.
    #
    # The container around it moved too: WorkSet yielded a raw Hash until 7.3,
    # and a Sidekiq::Work since. This gem supports both.
    #
    # JobRecord is Sidekiq's own reader for a job, and normalises the string and
    # hash forms of a payload the same way `Sidekiq::Work#job` does.
    def self.add_executing(jids)
      ::Sidekiq::WorkSet.new.each do |_process_id, _thread_id, work|
        payload = work.respond_to?(:payload) ? work.payload : work["payload"]

        next unless payload

        jid = ::Sidekiq::JobRecord.new(payload).jid

        jids << jid if jid
      end
    end
    private_class_method :add_executing
  end
end
