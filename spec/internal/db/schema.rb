# frozen_string_literal: true

ActiveRecord::Schema.define do
  create_table :sidekiq_batches, force: true do |t|
    t.string   :description
    t.integer  :status,            null: false, default: 0
    t.integer  :total_jobs,        null: false, default: 0
    t.jsonb    :callbacks,         null: false, default: {}
    t.jsonb    :callbacks_fired,   null: false, default: {}
    t.jsonb    :context,           null: false, default: {}
    t.string   :failure_policy
    t.integer  :failure_tolerance
    t.jsonb    :enrollment_error
    t.datetime :completed_at
    t.datetime :callback_fired_at

    t.timestamps
  end

  add_index :sidekiq_batches, %i[status callback_fired_at]
  add_index :sidekiq_batches, %i[status created_at]

  create_table :sidekiq_batch_jobs, force: true do |t|
    t.references :sidekiq_batch, null: false, foreign_key: { on_delete: :cascade }
    t.string  :jid,           null: false
    t.string  :worker_class,  null: false
    t.jsonb   :args,          null: false, default: []
    t.integer :status,        null: false, default: 0
    t.string  :error_class
    t.text    :error_message

    t.timestamps
  end

  add_index :sidekiq_batch_jobs, :jid, unique: true
  add_index :sidekiq_batch_jobs, %i[sidekiq_batch_id status]
  add_index :sidekiq_batch_jobs, :updated_at
end
