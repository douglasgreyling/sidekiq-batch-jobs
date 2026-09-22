# frozen_string_literal: true

class SidekiqBatch
  class Announcement
    Fired = Struct.new(:event, :job_class, keyword_init: true)

    # `-> 'key' IS NULL`, not the jsonb `?` operator: sanitize_sql_array counts
    # every `?` in the statement as a bind placeholder, so a jsonb `?` would
    # raise `wrong number of bind variables` on the way to the database.
    CLAIM_SQL = <<~SQL.squish
      UPDATE sidekiq_batches
      SET callbacks_fired = callbacks_fired || jsonb_build_object(?, to_jsonb(NOW())),
          updated_at      = NOW()
      WHERE id = ? AND callbacks_fired -> ? IS NULL
    SQL

    def self.call(batch)
      new(batch).call
    end

    def initialize(batch)
      @batch = batch
    end

    # @return [Array<Fired>] one entry per callback actually enqueued
    def call
      # An unfinished batch has no outcome to announce, and claiming here would
      # spend the announcement before there is anything to announce.
      return [] unless @batch.terminal?

      fired = events.filter_map { |event| fire(event) }

      resolve!
      @batch.reload

      fired
    end

    private

    attr_reader :batch

    def events
      ["complete", batch.failed_status? ? "failure" : "success"]
    end

    def fire(event)
      job_class_name = batch.callbacks[event]

      # Nothing registered for this event, so there is nothing to send — but the
      # announcement is still resolved, and the claim is what records that.
      # Without it the batch matches the orphaned-callback scope on every run
      # until grooming deletes it.
      return claim_only(event) if job_class_name.blank?

      # Resolved before the transaction opens. A NameError from a mistyped
      # callback class must not roll back a sibling event's claim, and must not
      # leave a push half-done.
      push(event, job_class_name, job_class_name.constantize)
    rescue StandardError => e
      ::Sidekiq::Batch::Jobs.config.alert(
        "SidekiqBatch ##{batch.id}: `#{event}` callback could not be fired " \
        "(#{e.class}: #{e.message}). The reaper will retry it."
      )

      nil
    end

    def claim_only(event)
      claim!(event)

      nil
    end

    def push(event, job_class_name, worker)
      fired = nil

      SidekiqBatch.transaction do
        next unless claim!(event)

        # Inside the transaction on purpose: see CallbackTarget for why an
        # ActiveJob callback cannot be sent with `perform_later`.
        CallbackTarget.enqueue(worker, batch.id)

        fired = Fired.new(event: event, job_class: job_class_name)
      end

      fired
    end

    def claim!(event)
      execute(CLAIM_SQL, event, batch.id, event).positive?
    end

    def resolve!
      conditions = Array.new(events.size, "callbacks_fired -> ? IS NOT NULL").join(" AND ")

      execute(<<~SQL.squish, batch.id, *events)
        UPDATE sidekiq_batches SET callback_fired_at = NOW(), updated_at = NOW()
        WHERE id = ? AND callback_fired_at IS NULL AND #{conditions}
      SQL
    end

    def execute(sql, *binds)
      SidekiqBatch.connection.exec_update(SidekiqBatch.sanitize_sql_array([sql, *binds]))
    end
  end
end
