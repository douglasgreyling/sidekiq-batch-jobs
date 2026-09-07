# frozen_string_literal: true

module Sidekiq
  module Batch
    module Jobs
      # The tables this version of the gem expects, as data rather than as a
      # `create_table` block, so the upgrade generator can diff them against a
      # host application's real schema and emit only what is missing. That is
      # what lets one command upgrade a database from any earlier version,
      # rather than a per-release migration the user has to apply in order.
      #
      # The install generator's template is this same schema written out for a
      # fresh database. Two files that have to agree, and the upgrade generator
      # spec catches it when they stop: run against a database built from the
      # current schema, this diff has to come out empty.
      module Schema
        BATCHES = :sidekiq_batches
        JOBS    = :sidekiq_batch_jobs

        TABLES = [BATCHES, JOBS].freeze

        # [name, type, options]. `id` and the timestamps are left out
        # deliberately: both have been on both tables since 0.1.0, and neither
        # is something an upgrade could sensibly add to a populated table.
        COLUMNS = {
          BATCHES => [
            [:description,       :string,   {}],
            [:status,            :integer,  { null: false, default: 0 }],
            [:total_jobs,        :integer,  { null: false, default: 0 }],
            [:complete_count,    :integer,  {}],
            [:failed_count,      :integer,  {}],
            [:callbacks,         :jsonb,    { null: false, default: {} }],
            [:callbacks_fired,   :jsonb,    { null: false, default: {} }],
            [:context,           :jsonb,    { null: false, default: {} }],
            [:failure_policy,    :string,   {}],
            [:failure_tolerance, :integer,  {}],
            [:enrollment_error,  :jsonb,    {}],
            [:completed_at,      :datetime, {}],
            [:callback_fired_at, :datetime, {}]
          ].freeze,
          JOBS    => [
            [:sidekiq_batch_id, :bigint,  { null: false }],
            [:jid,              :string,  { null: false }],
            [:worker_class,     :string,  { null: false }],
            [:args,             :jsonb,   { null: false, default: [] }],
            [:status,           :integer, { null: false, default: 0 }],
            [:error_class,      :string,  {}],
            [:error_message,    :text,    {}]
          ].freeze
        }.freeze

        # [columns, options].
        INDEXES = {
          BATCHES => [
            [%i[status callback_fired_at], {}],
            [%i[status created_at],        {}]
          ].freeze,
          JOBS    => [
            [%i[jid],                      { unique: true }],
            [%i[sidekiq_batch_id status],  {}],
            [%i[updated_at],               {}]
          ].freeze
        }.freeze

        # Indexes an older version created that a current one should not keep.
        # The bare `status` index goes because both composites above lead with
        # `status`, and Postgres serves a status-only lookup from either.
        SUPERSEDED_INDEXES = {
          BATCHES => [%i[status]].freeze
        }.freeze
      end
    end
  end
end
