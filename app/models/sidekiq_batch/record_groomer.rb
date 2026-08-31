# frozen_string_literal: true

class SidekiqBatch
  class RecordGroomer
    CHUNK_SIZE = 10_000

    # @return [Integer] number of batches deleted
    def self.call
      delete(terminal) + delete(abandoned)
    end

    def self.terminal
      SidekiqBatch.where(status: %w[succeeded failed])
                  .where(created_at: ...(Time.current - ::Sidekiq::Batch::Jobs.config.retention))
    end
    private_class_method :terminal

    def self.abandoned
      config = ::Sidekiq::Batch::Jobs.config
      cutoff = Time.current - [config.retention, config.stuck_after * 2].max

      SidekiqBatch.where(status: "pending").where(created_at: ...cutoff)
    end
    private_class_method :abandoned

    def self.delete(scope)
      scope.in_batches(of: CHUNK_SIZE).sum(&:delete_all)
    end
    private_class_method :delete
  end
end
