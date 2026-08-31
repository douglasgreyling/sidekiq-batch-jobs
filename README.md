# sidekiq-batch-jobs

Batch tracking and completion callbacks for Sidekiq, backed by ActiveRecord (PostgreSQL).

A hand-rolled alternative to Sidekiq Pro batches. Group a set of `perform_async` calls into a batch, persist their state in the database, and fire callback workers when the batch finishes. You decide what counts as a failure: one bad job, all of them, or some tolerance in between.

Tested against Ruby 3.0–3.4, Rails 6.1–8.0, Sidekiq 7–8.

## Contents

- [Installation](#installation)
  - [Configuration](#configuration)
- [Usage](#usage)
  - [The four steps](#the-four-steps)
  - [The `context` column](#the-context-column)
  - [What the `jobs` block does](#what-the-jobs-block-does)
  - [What a callback worker receives](#what-a-callback-worker-receives)
  - [The three events](#the-three-events)
  - [Deciding what counts as a failure](#deciding-what-counts-as-a-failure)
  - [Inspecting a batch from anywhere](#inspecting-a-batch-from-anywhere)
  - [Testing your batches](#testing-your-batches)
- [Monitoring and maintenance](#monitoring-and-maintenance)
  - [What the reaper repairs](#what-the-reaper-repairs)
  - [What the groomer deletes](#what-the-groomer-deletes)
  - [Watching for problems](#watching-for-problems)
  - [Three things the reaper cannot see](#three-things-the-reaper-cannot-see)
  - [Driving them yourself](#driving-them-yourself)
- [Development](#development)
  - [Running things](#running-things)
  - [The three lanes](#the-three-lanes)
  - [Changing versions](#changing-versions)
- [Contributing](#contributing)

## Installation

Add the gem:

```ruby
gem "sidekiq-batch-jobs"
```

Then generate the migration and run it:

```bash
bin/rails g sidekiq:batch:jobs:install
bin/rails db:migrate
```

That is the whole setup. The gem registers its client middleware, server middleware and
death handler for you at boot, and again after every code reload.

**Run batched jobs in a real Sidekiq process.** An embedded processor
(`Sidekiq.configure_embed`) never runs this gem's server middleware, so its jobs stay
`pending` even when they succeed, and the reaper eventually marks them failed.

### Configuration

Every setting is optional and has a working default. To change one, do it in an initializer:

```ruby
# config/initializers/sidekiq_batch_jobs.rb
Sidekiq::Batch::Jobs.configure do |config|
  config.base_class_name   = "ApplicationRecord"
  config.stuck_after       = 2.hours
  config.retention         = 30.days
  config.failure_policy    = { tolerate: "1%" }
  config.maintenance_queue = "cron"
  config.on_alert          = ->(message) { Ops.notify(message) }
end
```

| Setting | Accepts | Default | What it does |
| --- | --- | --- | --- |
| `base_class_name` | a class name, as a String | `"ActiveRecord::Base"` | What the two models inherit from |
| `stuck_after` | a duration, or a number of seconds | `2.hours` | How long a `running` batch must be quiet before the reaper inspects it |
| `retention` | a duration, or a number of seconds | `30.days` | How long a terminal batch is kept, measured from `created_at` |
| `failure_policy` | `:any_failure`, `:all_failed`, `{ tolerate: 10 }`, `{ tolerate: "5%" }` | `:any_failure` | What a new batch counts as a failure, unless it names its own |
| `maintenance_queue` | any Sidekiq queue name | `"default"` | Queue the reaper and groomer are enqueued to |
| `on_alert` | a callable taking one String, or `nil` to silence | logs a warning | Where the reaper reports anything it had to repair |
| `error_message_max` | an Integer | `4000` | Characters of an error message stored before truncation |
| `auto_install` | `true` / `false` | `true` | Whether the engine wires middleware and the death handler at boot |

**`maintenance_queue` is a free-form queue name, not a choice from a list.** `"cron"` above is
just a common convention for scheduled work; `"low"`, `"maintenance"` or the default `"default"`
are equally valid. The one requirement is that a Sidekiq process actually consumes the queue you
name. Point it at a queue nothing is listening to and the reaper and groomer sit there
unprocessed, which looks exactly like the bugs they exist to fix. See
[Monitoring and maintenance](#monitoring-and-maintenance) for scheduling them.

**`stuck_after` wants headroom, not precision.** It is the age at which a quiet batch is assumed
broken, so it has to sit comfortably above both Sidekiq's ~30 second heartbeat expiry and your
longest queue latency. Otherwise the reaper starts fixing batches that were only ever slow.

**Give `base_class_name` a String, not the constant, and set it in an initializer.** A Class is
accepted but immediately reduced to its name, and naming it there would autoload your
application during boot. A name is resolved only when the models load, and re-resolved on every
reload, so a reloaded base class never goes stale. That first load is also why setting it any
later does nothing, because the models are already defined, and why a name that resolves to
nothing raises then rather than at assignment.

`stuck_after`, `retention` and `failure_policy` are the three checked as you assign them, so a
typo raises while the initializer is running rather than hours later, inside the one statement
that decides a batch's outcome. `on_alert` is not, but an alert channel that raises is caught
and logged rather than taking down the reaper run that was trying to report through it.

If you need to control middleware order yourself, set `auto_install = false` and call
`Sidekiq::Batch::Jobs.install!` from a `to_prepare` block of your own.

## Usage

A batch is a group of Sidekiq jobs whose collective fate you care about. Once every job in the batch ends in a terminal state, the batch is judged (succeeded or failed) and your callback workers fire. You typically use a batch when there's "fan-in" work to do after a bunch of independent jobs finish. For example: rebuilding a derived dataset after rescoring, sending one summary email after a thousand individual notifications, or marking an import as ready once all rows are processed.

### The four steps

```ruby
# 1. Create the batch. `context` is a slot for whatever the callbacks will
#    need, since they only receive the batch id, not the surrounding closure.
batch = SidekiqBatch.create!(
  description: "Rescore leaderboard #{leaderboard.id}",
  context: {
    "leaderboard_id" => leaderboard.id,
    "triggered_by"   => current_user.id,
    "reason"         => "manual rescore from admin panel",
  },
)

# 2. Register what runs when the batch finishes. `:complete` fires whatever
#    the outcome; `:success` and `:failure` name it.
batch.on(:complete, ReleaseRescoreLockWorker)
batch.on(:success, RebuildLeaderboardCacheWorker)
batch.on(:failure, AlertOpsOfFailedRescoreWorker)

# 3. Enqueue jobs *inside* the block, and they get enrolled automatically.
batch.jobs do
  leaderboard.entries.find_each do |entry|
    ScoreWorker.perform_async(entry.id)
  end
end

# 4. The batch is now running. Two callbacks fire once the last job lands in a
#    terminal state, possibly hours later, on a different worker process.
```

Register callbacks any time before the batch finishes; they are read fresh at completion.
But registering them here, beside the batch that owns them, is both the clearest option and
the only thread-safe one. `on` is a read-modify-write of one jsonb column, so two threads
registering different events can lose one. Registering on a batch that has already finished
raises: the announcement has been and gone.

### The `context` column

`SidekiqBatch#context` is a `jsonb` column for arbitrary per-batch metadata. The gem doesn't read it. It's a slot for *you* to pass information from the code that created the batch through to the callback worker, since the callback only receives `batch_id` and has to rehydrate everything else from the database.

Useful things to stash there:

- **Foreign keys** the callback needs (`leaderboard_id`, `import_id`, `tenant_id`).
- **Provenance** for debugging or audit (`triggered_by`, `via`, `request_id`).
- **Configuration** the callback should branch on (`notify_slack: true`, `recompute_strategy: "fast"`).

Keep it small and stable: it's metadata, not a payload. If you find yourself stuffing large arrays in there, that's a sign the data should live in its own table with a `sidekiq_batch_id`.

### What the `jobs` block does

The block switches on a thread-local "enrollment context." While it runs:

- Every `perform_async` / `perform_bulk` / `set(...).perform_async` made on this thread is intercepted by the client middleware.
- Each pushed job gets a `SidekiqBatchJob` row (jid, worker class, args) written to Postgres **before** Sidekiq pushes the payload to Redis. That ordering is the whole point: when the job later runs, the server middleware is guaranteed to find its row.
- Only this thread's pushes count. Jobs enqueued outside the block, or by the batch's own workers once they are running, are not enrolled, which is what keeps a batch's membership predictable.

When the block returns, `total_jobs` is stamped and the batch moves from `pending` to
`running` in a single statement, and a completion check runs straight away. A batch whose
jobs all finish that fast can already be terminal by the time `jobs` returns.

Three ways the block can end badly:

- **It enrolls nothing.** The batch row is destroyed and `EmptyEnrollmentError` raised. There is nothing to wait for, so leaving the row behind would only leak.
- **It raises.** Whatever it already enqueued is running, so the batch is started anyway and stamped with `enrollment_error`, then your exception propagates unchanged. That batch finishes `failed` whatever its policy says. See [Deciding what counts as a failure](#deciding-what-counts-as-a-failure).
- **It goes quiet for longer than `stuck_after`.** The reaper adopts the batch and the block raises `AdoptedError` rather than overwrite it. See [Three things the reaper cannot see](#three-things-the-reaper-cannot-see).

**A batch is enrolled once.** `total_jobs` is stamped when the block returns, and the batch
may have announced its outcome by the time you get control back, so there is no reopening one
to add more jobs the way Sidekiq Pro allows. A second `jobs` block on the same batch raises
`AlreadyStartedError`. Create a new batch instead.

**`jobs` cannot run inside an open transaction.** It raises `TransactionError`, including
for a transaction opened *inside* the block. Enrollment rows have to be committed before
their jobs reach Redis; otherwise a worker can start before its row is visible, or a rollback
can discard the row for a job that is already running. Nesting one `jobs` block in another
raises `NestedError` for the same reason a batch's membership has to stay unambiguous.

**Prefer plain Sidekiq workers inside the block.** ActiveJob pushes through Sidekiq, so
`perform_later` and `deliver_later` are enrolled too, including ones buried in code the block
calls. Usually that is merely surprising. `retry_on` is worse: ActiveJob catches the failure
itself and queues a *new* job, so Sidekiq only ever sees the original succeed. The batch marks
that row complete and can report success while the work is still failing and retrying.

Beyond that you don't have to think about jid tracking, race conditions, or middleware
ordering. You just write the block.

### What a callback worker receives

Every callback gets one argument: the batch id. From there it can inspect the batch's full state:

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

### The three events

Nothing fires until the batch has **finished**, meaning every enrolled job is in a terminal
state. Then it raises two events: the one that fires whatever happened, and the one that
names what happened.

| Event | Fires when |
| --- | --- |
| `:complete` | every job finished, whatever the outcome. **Always** |
| `:success` | every job finished, and the failure policy says the batch passed |
| `:failure` | every job finished, and the failure policy says it failed |

`:success` and `:failure` are mutually exclusive; `:complete` fires alongside whichever
applies. So "always release the lock, and separately page me when it went badly" is two
registrations rather than a worker that has to do both jobs.

This is Sidekiq Pro's vocabulary, deliberately: `:complete` there also means "done, one way
or another". If you are porting from Pro, `on(:complete, …)` keeps its meaning.

### Deciding what counts as a failure

By default a single failed job fails the whole batch. For a bulk import or a backfill that
is usually too strict: three bad rows out of ten thousand is a Tuesday, not an incident. Set
a policy per batch, or globally through `config.failure_policy`:

```ruby
SidekiqBatch.create!(description: "…", failure_policy: :any_failure)       # the default
SidekiqBatch.create!(description: "…", failure_policy: :all_failed)
SidekiqBatch.create!(description: "…", failure_policy: { tolerate: 10 })
SidekiqBatch.create!(description: "…", failure_policy: { tolerate: "5%" })
```

| Policy | The batch fails when |
| --- | --- |
| `:any_failure` | any job failed. Use for anything transactional |
| `:all_failed` | every job failed. Use for best-effort fan-outs where partial delivery is fine |
| `{ tolerate: 10 }` | more than 10 jobs failed |
| `{ tolerate: "5%" }` | more than 5% of `total_jobs` failed, rounded down |

All four are the same rule with a different threshold: *the batch fails when more jobs failed
than it tolerates*. It is evaluated inside the same atomic statement that transitions the
batch, so a policy never costs you a race.

Two edges worth knowing. A percentage rounds **down**, so a batch too small to earn any slack
tolerates nothing: 5% of 4 jobs is 0. And a tolerance wide enough to cover the whole batch
means even a total loss announces `:success`. `{ tolerate: "100%" }` never fails.

The policy decides the outcome; it does not decide what your callback does about it. A
`:success` callback can still read `batch.progress` and act on the failures it forgave.

**One thing no policy forgives.** If the `batch.jobs { … }` block itself raises or its process
dies partway through, the batch is failed regardless. It was never fully enqueued, and a
tolerance says "some jobs may fail", not "some jobs may never have been queued at all".
`batch.enrollment_error` records what happened.

**Write callbacks to be idempotent.** Delivery is at-least-once, not exactly-once. Each
callback is enqueued inside the same transaction that claims it, so a crash after the Redis
push but before the commit rolls that claim back and the reaper enqueues it again. That
ordering is deliberate: a rolled-back claim is recoverable, while a committed claim with no
push would need the reaper anyway. Events are claimed **separately**, so a callback that
cannot be delivered never causes a redelivery of one that already went out. Sidekiq asks
idempotency of every worker, so this is rarely extra work.

### Inspecting a batch from anywhere

```ruby
batch.progress
# => { total: 1247, complete: 1101, failed: 3, pending: 143 }

batch.percentage_progress
# => 88.29
# Terminal jobs, complete *and* failed, as a percentage of total_jobs,
# rounded to two decimal places. 0.0 for an empty batch.

batch.eta
# => 142 seconds
# An ActiveSupport::Duration projecting the outstanding work forward at the
# rate observed since the batch was created. nil when no estimate is possible
# (not running, no jobs, or nothing finished yet); zero once all are terminal.

batch.status            # "pending" | "running" | "succeeded" | "failed"
batch.terminal?         # true once the batch has finished, either way
batch.completed_at      # nil until the batch finishes
batch.total_jobs        # stamped when the jobs {} block returns; 0 before that
batch.context           # the jsonb hash you stashed when creating the batch

batch.failure_policy    # "any_failure" | "all_failed" | "tolerate_jobs" | "tolerate_percent"
batch.failure_tolerance # the number beside a tolerating policy, else nil

batch.enrollment_error  # nil normally; {"class" =>, "message" =>} if the
                        # jobs {} block never finished enqueueing
batch.callbacks_fired   # event => when that callback went out
```

Each enrolled job has a row of its own:

```ruby
batch.pending_jobs      # ActiveRecord relations of SidekiqBatchJob
batch.failed_jobs
batch.completed_jobs

job = batch.failed_jobs.first
job.status          # "pending" | "complete" | "failed"
job.jid             # the Sidekiq job id
job.worker_class    # and job.args: what was pushed
job.error_class     # set when the job failed
job.error_message   # truncated to config.error_message_max
```

Note the two vocabularies. A **job** that finished successfully is `complete`; a **batch**
that did is `succeeded`. The difference is deliberate: `:complete` is the event that fires
whatever the outcome, so a batch status called `complete` would mean something quite
different from the event sitting right beside it.

### Testing your batches

Batches do not finish by themselves in a test suite, and it is worth knowing why before you go
looking for the bug.

**In fake mode** (Sidekiq's default) pushed jobs go into an array instead of running, so the
enrollment rows stay `pending` and the batch stays `running`. That is usually what you want:
assert on `batch.total_jobs` and the rows, then drive the outcome yourself.

```ruby
batch.jobs { RescoreWorker.perform_async(1) }

expect(batch.total_jobs).to eq(1)
expect(RescoreWorker.jobs.size).to eq(1)

batch.sidekiq_batch_jobs.each(&:mark_complete!)
batch.attempt_completion!            # now it is `succeeded` and the callbacks are queued
```

**In inline mode** jobs run at push time, but Sidekiq's inline path uses its own middleware
chain, which is empty by default. Add this gem's middleware to it or nothing will be tracked:

```ruby
Sidekiq::Testing.server_middleware { |chain| chain.add(SidekiqBatch::Middleware) }
```

Even then, an inline job runs *while the block is still open*, so anything it enqueues joins
the batch. Fake mode avoids that entirely, which is why this gem's own suite uses it.

## Monitoring and maintenance

Two cron jobs keep batch state honest. Schedule both:

```yaml
# config/cron.yml, for sidekiq-cron
sidekiq_batch_reaper:              # repairs batches that got stuck
  cron:  '*/30 * * * *'
  class: 'SidekiqBatch::ReaperWorker'

sidekiq_batch_groomer:             # deletes batches that have aged out
  cron:  '0 3 * * *'
  class: 'SidekiqBatch::GroomerWorker'
```

Both are ordinary Sidekiq workers, enqueued to `config.maintenance_queue`. Both retry 3 times
rather than Sidekiq's default 25, because the next scheduled run does the same work anyway: a
persistent failure should surface quickly instead of retrying quietly for weeks.

### What the reaper repairs

Three things go wrong that the job which hit them cannot fix for itself:

- **A job leaves Redis and never reports back.** SIGKILL, an OOM kill, an evicted pod. Its
  row stays `pending`, so the batch never finishes and never announces. Killing a batched
  job's retries from the Sidekiq web UI lands here too: the **Kill All** button moves jobs to
  the dead set without running death handlers, so the reaper is the only thing that notices.
- **A batch finishes but never announces.** The process died in the moment between the batch
  going terminal and its callbacks reaching Redis.
- **A `jobs { … }` block is killed partway through enrolling.** Its batch is left `pending`
  with jobs already queued and running, and nothing else in the gem looks at `pending`. Left
  alone it would never complete, never announce, and never be cleaned up. (An ordinary
  exception in the block does not need the reaper; it is handled on the spot.)

The reaper only touches batches that have been quiet for longer than `config.stuck_after`, so
it never races Sidekiq's own recovery of a crashed process. A batch that raises while being
reaped is skipped and reported, so one bad batch cannot strand the rest of the run.

### What the groomer deletes

Terminal batches older than `config.retention`. Age is measured from `created_at`, not
`completed_at`, so a batch that ran for a week is deleted a week sooner than one that finished
immediately. Enrolled job rows go with it through the foreign key's `ON DELETE CASCADE`, and
deletion is chunked, so a large backlog commits as it goes rather than putting millions of
rows in one transaction.

It also collects long-abandoned `pending` batches, as a backstop for hosts that never
scheduled the reaper. That cutoff always leaves the reaper time to adopt them first, however
short you set `retention`: deleting a pending batch before it can be adopted would destroy
live data.

### Watching for problems

Anything the reaper actually repaired goes to `config.on_alert`. Nothing routine is reported,
so every message is worth reading:

```
SidekiqBatch #4821 (Rescore leaderboard 42) had 3 stuck job(s) marked failed.
Status is now `failed`. JIDs: f1b2c3d4e5f6, 0a9b8c7d6e5f.
```

The default logs a warning. Point `on_alert` somewhere you actually look; it is the only
unprompted signal the gem gives you.

Silence is not proof the reaper is running, though: a healthy system and an unscheduled reaper
look identical from here. For positive confirmation, watch the job itself in Sidekiq's
dashboard or your cron scheduler's UI.

To go looking on your own:

```ruby
# Enum scopes carry a `_status` suffix, so it is `running_status`, not `running`.
SidekiqBatch.running_status.where(created_at: ..2.hours.ago)   # running longer than expected
SidekiqBatch.where.not(enrollment_error: nil)                  # never finished enqueueing
SidekiqBatch.failed_status.order(created_at: :desc).limit(20)  # most recent failures

# Finished, but not every callback has gone out. The reaper fixes these; a persistent
# backlog here means it is not running.
SidekiqBatch.where(status: %w[succeeded failed], callback_fired_at: nil)
```

Once you have a batch, [Inspecting a batch from anywhere](#inspecting-a-batch-from-anywhere)
covers reading its progress and its individual jobs.

### Three things the reaper cannot see

**More than one Redis instance.** The reaper decides a job has vanished by checking every
queue, sorted set, and executing worker on `Sidekiq.default_configuration`'s Redis. Jobs
pushed to a different pool (`Sidekiq::Client.via`, or a sharded setup) are enrolled by the
client middleware but invisible to that check, so the reaper will eventually mark them all
failed. Use this gem with a single Redis instance, or do not schedule the reaper.

**A job picked up seconds ago.** `Sidekiq::Workers` is backed by process heartbeats and can be
a few seconds stale. A job dequeued in that window appears in neither the queue nor the
executing set, so it can be marked failed while it is in fact running, and its later success
cannot be recorded. The window is small, but it is widest exactly when a long-quiet batch
finally gets picked up.

**A `jobs { … }` block that stalls.** Enrollment writes a row per job, so a block working
steadily through millions of pushes is never mistaken for a dead one. But one that goes
completely quiet for longer than `stuck_after` (blocked on a rate-limited API, say) looks
exactly like a process that died, and the reaper will start its batch without it. The block
then raises `AdoptedError` when it finishes, rather than overwriting the reaper's work and
stranding everything it enrolled in the meantime.

The last two have the same fix: keep `stuck_after` comfortably larger than your longest queue
latency, so slow is never mistaken for dead.

### Driving them yourself

Both cron workers are thin wrappers. If you would rather run the work from your own ActiveJob,
a rake task, or a console, the underlying objects are public and return what they did:

```ruby
SidekiqBatch::AbandonedEnrollmentReaper.call # => [Result(batch:, total_jobs:)]
SidekiqBatch::StuckJobReaper.call            # => [Result(batch:, jids:)]
SidekiqBatch::OrphanedCallbackReaper.call    # => [Result(batch:, event:, job_class:)], up to two per batch
SidekiqBatch::RecordGroomer.call             # => Integer, batches deleted
```

## Development

Everything runs in Docker, so Docker Compose is the only prerequisite. After cloning:

```bash
bin/setup   # builds both images and resolves every lane (a few minutes)
bin/test    # runs the suite
```

Run `bin/setup` again whenever the `Dockerfile`, the `Gemfile` or `Appraisals` changes.

### Running things

```bash
bin/test                                        # rails-6.1, the default lane
bin/test spec/models                            # arguments pass through to rspec
bin/test spec/models/sidekiq_batch_spec.rb:42   # including a single example
bin/test --lane rails-8.0                       # one specific lane
bin/test --all                                  # every lane, in order

bin/shell                                       # interactive shell in the default lane
bin/shell rails-8.0                             # or in another one
```

Rake tasks run inside a lane rather than on your host, so reach them through `bin/shell`:

```bash
bundle exec rake            # specs and RuboCop, the default task
bundle exec rake rubocop    # RuboCop on its own
bundle exec rake audit      # this lane's lockfile against the ruby-advisory-db
```

`audit` sits outside the default task because it needs network access.

> **Expect advisories on the older lanes.** The `rails-6.1` and `rails-7.1` lockfiles already
> hold the newest release in those series (6.1.7.10, 7.1.6), and both series are past security
> support, so roughly 20 advisories each have no version to move to. nokogiri is stuck for the
> same reason: 1.18+ requires Ruby >= 3.1. CI audits every lane but only *fails* on `rails-8.0`,
> which is clean. Green CI does not mean "no known advisories on Rails 6.1".

### The three lanes

| Lane | Ruby | Rails | Sidekiq | Why it exists |
| --- | --- | --- | --- | --- |
| `rails-6.1` | 3.0.7 | 6.1.7 | 7.3.10 | The app this gem was extracted from |
| `rails-7.1` | 3.0.7 | 7.1 | 7.3 | Exercises `EnumCompat`'s `>= 7` branch |
| `rails-8.0` | 3.4.6 | 8.0 | 8.x | ActiveRecord 8 removed the hash form of `enum` |

`rails-6.1` and `rails-8.0` are the two that matter most. No single lane can cover both
branches of the `enum` shim, because 6.1 accepts only the hash form and 8.0 only the
positional one.

**Two images, and Ruby is why.** Appraisal varies gem versions; it cannot vary Ruby. Rails 8
and Sidekiq 8 both require Ruby >= 3.2, so `rails-8.0` cannot run on the Ruby 3.0.7 image that
matches the extraction target. `docker-compose.yml` pairs each lane with a Ruby that can run
it, and CI mirrors that pairing.

Postgres and Redis come up through compose and are gated on healthchecks, so there is no wait
loop to care about. Postgres data is on tmpfs, so `docker compose down` any time. The suite
boots a minimal Rails app under `spec/internal/` with
[Combustion](https://github.com/pat/combustion).

### Changing versions

Edit `Appraisals`, then run `bin/setup` to regenerate `gemfiles/` and re-resolve. Both the
generated gemfiles and their lockfiles are committed, so CI is reproducible.

Development dependencies live in the `Gemfile`, not the gemspec, because a `~>` cap there
would pin the whole matrix to one era of test tooling and no single constraint spans it
(shoulda-matchers 6.x needs Ruby >= 3.0.5, 8.x needs >= 3.3).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/douglasgreyling/sidekiq-batch-jobs.
