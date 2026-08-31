# frozen_string_literal: true

class SidekiqBatch
  class OrphanedCallbackReaper
    Result = Struct.new(:batch, :event, :job_class, keyword_init: true)

    # `find_each`, not a plain each: a genuine backlog — a reaper that has been
    # down, or a burst of batches that died mid-announcement — should not be
    # materialised in one go inside a worker process.
    def self.call
      results = []

      orphaned.find_each { |batch| results.concat(fire_for(batch)) }

      results
    end

    def self.fire_for(batch)
      batch.fire_callbacks.map do |fired|
        Result.new(batch: batch, event: fired.event.to_sym, job_class: fired.job_class)
      end
    rescue StandardError => e
      ::Sidekiq::Batch::Jobs.config.alert(
        "SidekiqBatch ##{batch.id}: orphaned `#{batch.status}` callback could not be " \
        "fired (#{e.class}: #{e.message}). Skipped."
      )

      []
    end
    private_class_method :fire_for

    def self.orphaned
      SidekiqBatch.where(status: %w[succeeded failed], callback_fired_at: nil)
    end
    private_class_method :orphaned
  end
end
