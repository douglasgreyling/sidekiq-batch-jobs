# frozen_string_literal: true

class SidekiqBatch
  class OrphanedJobError < StandardError
    def initialize(jid:)
      super("SidekiqBatchJob jid=#{jid} is not present anywhere in Sidekiq — orphaned by the stuck-job reaper")
    end
  end
end
