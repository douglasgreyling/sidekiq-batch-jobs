# sidekiq-batch-jobs

Batch tracking and completion callbacks for Sidekiq, backed by ActiveRecord (PostgreSQL).

A hand-rolled alternative to Sidekiq Pro batches. Group a set of `perform_async` calls into a batch, persist their state in the database, and fire a callback worker when the batch finishes — success or failure.

## Installation

Add to your Gemfile:

```ruby
gem "sidekiq-batch-jobs"
```

Then run the install generator and migrate:

```bash
bin/rails g sidekiq:batch:jobs:install
bin/rails db:migrate
```

The gem registers its client middleware, server middleware, and death handler automatically at boot.

To opt out (e.g. you need full control over middleware order), set this in `config/application.rb` before Rails boots:

```ruby
Sidekiq::Batch::Jobs.auto_install = false
```

Then either call `Sidekiq::Batch::Jobs.install!` from your own `config/initializers/sidekiq.rb`, or wire the three pieces by hand:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_client do |config|
  # Outermost on the client chain so any dedupe/suppression middleware
  # registered later with `chain.add` gets the final say on whether a
  # push actually happens. We only enroll jobs that the chain agrees to push.
  config.client_middleware do |chain|
    chain.prepend SidekiqBatch::ClientMiddleware
  end
end

Sidekiq.configure_server do |config|
  # Same prepend for the server's own client chain — covers `perform_async`
  # calls made from inside a running worker.
  config.client_middleware do |chain|
    chain.prepend SidekiqBatch::ClientMiddleware
  end

  # `add` (not `prepend`) so this runs LAST in the server chain — outside
  # Sidekiq's retry middleware. That way we see the terminal disposition
  # of each attempt and only mark the row failed on the final retry.
  config.server_middleware do |chain|
    chain.add SidekiqBatch::Middleware
  end

  # Reconciles jobs that died without re-entering middleware (SIGKILL, OOM,
  # pod eviction). Without this, a killed job's batch row stays `pending`
  # forever and the batch never completes.
  config.death_handlers << ->(job, ex) { SidekiqBatch::Middleware.handle_death(job, ex) }
end
```

## Usage

A batch is a group of Sidekiq jobs whose collective fate you care about. Once every job in the batch ends in a terminal state, a callback worker fires — exactly once. You typically use a batch when there's "fan-in" work to do after a bunch of independent jobs finish: rebuilding a derived dataset after rescoring, sending one summary email after a thousand individual notifications, marking an import as ready once all rows are processed.

### The four steps

```ruby
# 1. Create the batch. Use `context` to stash any state the callback will need —
#    the callback only receives the batch id, not the surrounding closure, so
#    anything you'd otherwise close over goes here.
batch = SidekiqBatch.create!(
  description: "Rescore leaderboard #{leaderboard.id}",
  context: {
    "leaderboard_id" => leaderboard.id,
    "triggered_by"   => current_user.id,
    "reason"         => "manual rescore from admin panel",
  },
)

# 2. Register what happens when the batch finishes
batch.on(:complete, RebuildLeaderboardCacheWorker)
batch.on(:failure, AlertOpsOfFailedRescoreWorker)

# 3. Enqueue jobs *inside* the batch context — they get enrolled automatically
batch.jobs do
  leaderboard.entries.find_each do |entry|
    ScoreWorker.perform_async(entry.id)
  end
end

# 4. The batch is now running. Your callback worker will be invoked when
#    the last job lands in a terminal state — possibly hours later, on a
#    completely different worker process.
```

### The `context` column

`SidekiqBatch#context` is a `jsonb` column for arbitrary per-batch metadata. The gem doesn't read it — it's a slot for *you* to pass information from the code that created the batch through to the callback worker, since the callback only receives `batch_id` and has to rehydrate everything else from the database.

Useful things to stash there:

- **Foreign keys** the callback needs (`leaderboard_id`, `import_id`, `tenant_id`).
- **Provenance** for debugging or audit (`triggered_by`, `via`, `request_id`).
- **Configuration** the callback should branch on (`notify_slack: true`, `recompute_strategy: "fast"`).

Keep it small and stable — it's metadata, not a payload. If you find yourself stuffing large arrays in there, that's a sign the data should live in its own table with a `sidekiq_batch_id`.

### What `batch.jobs do … end` actually does

The block establishes a thread-local "enrollment context." While the block runs:

- Every `perform_async` / `perform_bulk` / `set(...).perform_async` call made on this thread is intercepted by the client middleware.
- For each pushed job, a `SidekiqBatchJob` row is written to Postgres with the job's `jid`, worker class, and args — **before** Sidekiq pushes the payload to Redis. That ordering is the whole point: when the worker later runs and the server middleware looks for a matching row, it's guaranteed to find one.
- When the block returns, the batch transitions from `pending` to `running` and the context is cleared.
- Jobs enqueued **outside** the block are not enrolled and don't count toward this batch's completion. Same for jobs that *child* workers enqueue while running — only the original thread's enqueues are captured (by design — keeps the batch's scope predictable).

You don't have to think about jid tracking, race conditions, or middleware ordering — that's the gem's job. You just write the block.

### What the callback worker receives

The callback gets one argument: the batch id. From there it can inspect the batch's full state:

```ruby
class RebuildLeaderboardCacheWorker
  include Sidekiq::Worker

  def perform(batch_id)
    batch          = SidekiqBatch.find(batch_id)
    leaderboard_id = batch.context.fetch("leaderboard_id")

    Rails.logger.info "Batch #{batch.description} finished: #{batch.progress}"
    # => Batch Rescore leaderboard 42 finished: {total: 1247, complete: 1247, failed: 0, pending: 0}

    LeaderboardCacheRebuilder.run(leaderboard_id)
  end
end

class AlertOpsOfFailedRescoreWorker
  include Sidekiq::Worker

  def perform(batch_id)
    batch = SidekiqBatch.find(batch_id)

    batch.failed_jobs.find_each do |bj|
      Ops.notify(
        "Rescore worker died: #{bj.worker_class} args=#{bj.args} " \
        "error=#{bj.error_class}: #{bj.error_message}",
      )
    end
  end
end
```

Either `:complete` *or* `:failure` will fire — never both, never twice. `:complete` fires when every enrolled job succeeded; `:failure` fires the moment any job ends in a failed terminal state (retries exhausted, or `retry: false` workers that raised).

### Inspecting a batch from anywhere

```ruby
batch.progress
# => { total: 1247, complete: 1101, failed: 3, pending: 143 }

batch.pending_jobs    # ActiveRecord relation
batch.failed_jobs
batch.completed_jobs

batch.status          # "pending" | "running" | "complete" | "failed"
batch.completed_at    # nil while running, set on terminal transition
batch.context         # the jsonb hash you stashed when creating the batch
```

## Development

After checking out the repo, run `bin/setup` to install gem dependencies. Then run the suite with:

```bash
bin/test                  # starts Postgres via docker compose, then runs rspec
bin/test spec/models      # forwards args through to rspec
```

The test harness uses [Combustion](https://github.com/pat/combustion) to boot a minimal Rails app under `spec/internal/`, and a Postgres container defined in `docker-compose.yml`. The container uses an ephemeral tmpfs for its data directory, so it's safe to `docker compose down` at any time.

If you'd rather skip the wrapper, the manual flow is:

```bash
docker compose up -d
bundle exec rspec
docker compose down
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/douglasgreyling/sidekiq-batch-jobs.
