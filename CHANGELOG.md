# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-09-22

A support-window release. No behaviour changes, no schema change, and no API change beyond one
shim that the new floor makes dead.

### Breaking

- **Rails 6.1, 7.0 and 7.1 are no longer supported.** The gemspec now requires
  `activerecord >= 7.2, < 9`. Nothing in the gem stopped working on those versions, they are
  simply no longer tested against, and with 8.1 shipped they are all past Rails' own security
  support. Stay on 0.3.1 if you need them; it is unaffected by this release.
- **Ruby 3.0 is out, and the floor is 3.1.** Not our choice to make: Rails 7.2 requires
  Ruby >= 3.1, so supporting one sets the other.
- **`Sidekiq::Batch::Jobs::EnumCompat` is gone.** It existed only to bridge Rails 6.1's
  hash-form `enum` against the positional form 7.0 introduced, and with 7.2 as the floor every
  supported Rails takes the same branch. The models now call `enum` directly. Nothing
  downstream changes, because the generated surface is identical: `.statuses`, the
  `pending_status?` predicates and the `pending_status` scopes are all still there. Only a host
  that referenced the module by name is affected, which it had no reason to.

### Added

- A `rails-8.1` lane, so the newest Rails series is actually covered rather than merely
  permitted by the `< 9` ceiling.

### Changed

- The lanes are now `rails-7.2` (Ruby 3.1.7, Sidekiq 7.3), `rails-8.0` and `rails-8.1` (both
  Ruby 3.4.6, Sidekiq 8). `rails-7.2` carries the most weight: it is the only lane on Ruby 3.1
  and the only one on Sidekiq 7, so it alone proves the bottom of both declared ranges.
- The development image moved from Ruby 3.0.7 to 3.1.7, which also moves its base from Debian
  bullseye to bookworm. Worth knowing because the bullseye apt mirror had begun 404ing on
  `git`, which left `bin/setup` and `bin/test` unable to build an image at all. Both work
  again.
- `rake audit` now hard-fails on both Rails 8 lanes, where before only one lane was held to
  that. `rails-7.2` still soft-fails, for a reason that has nothing to do with Rails: it runs
  Ruby 3.1, which caps nokogiri at 1.18.10 because 1.19 requires 3.2, and those advisories have
  no version to move to. nokogiri is test-only, reaching the lockfile through actionview, so
  the gem declares no runtime dependency on it and nothing reaches a host application.
- Development dependencies now cap `json` below 3.0. The September 2026 release dropped the
  `quirks_mode` keyword from `generate` and changed `parse`'s arity, which breaks every Rails
  series this gem supports. Deliberately in the Gemfile rather than the gemspec: it is Rails'
  incompatibility to resolve, and capping a host application's json for them would be
  overreach.

### Upgrading from 0.3.1

Nothing to run. On Rails 7.2+ and Ruby 3.1+, `bundle update sidekiq-batch-jobs` is the whole
upgrade: no migration, no configuration change, no API change.

On Rails 7.1 or older, Bundler will simply decline the upgrade and leave you on 0.3.1.

## [0.3.1] - 2026-09-08

### Fixed

- **The reaper could fail jobs that were still running.** `JidIndex` read an executing job's id
  as `work.payload["jid"]`, but `payload` holds the job as a JSON *string* rather than a nested
  object, so that expression is String indexing: it finds the key *name* in the JSON and returns
  the literal `"jid"`, for every job on the cluster. The live-jid index filled with a single
  constant, no executing job was ever found in it, and `StuckJobReaper` marked rows orphaned
  whose jobs were running perfectly well. Unrecoverable once it happened, since the job's own
  `complete!` then finds the row no longer pending and leaves it failed.

  Reaching it took a batch quiet for `stuck_after` (two hours by default), so the exposure was
  long-running jobs, which is much of what batches are for. Present since 0.1.0.

  The example covering this branch built its Redis fixture with a nested Hash, a shape no
  Sidekiq version writes, so it passed throughout. It now writes the string form, alongside one
  example pinning that shape and one asserting the literal `"jid"` never reaches the index.

- **`JidIndex` raised `NoMethodError` on Sidekiq 7.0 to 7.2.** `WorkSet` yielded a raw Hash
  until 7.3 and a `Sidekiq::Work` since, and the code called `#payload` on whatever it got. The
  gemspec has always allowed `sidekiq >= 7.0`, and every CI lane resolves 7.3 or newer, so no
  lane exercised the older shape. Both are now read through `Sidekiq::JobRecord`, which
  normalises the string and hash forms the way `Sidekiq::Work#job` does.

No schema change, so nothing to migrate.

## [0.3.0] - 2026-09-07

### Breaking

- **A migration is required, and the new code does not work without it.** The completion
  statement writes both new columns, so against an unmigrated database every completion check
  raises `PG::UndefinedColumn` and `#progress` raises `NameError` on a finished batch. See
  *Upgrading from 0.2.0* below.

### Added

- `complete_count` and `failed_count` on `sidekiq_batches`, stamped by the completion statement
  in the same `UPDATE` that transitions the batch. `#progress` reads them back, so a finished
  batch reports its counts without touching a job row, and `#percentage_progress` now answers
  100.0 from the status alone: a batch only transitions once nothing is pending, so a terminal
  one has nothing left to count. A running batch counts rows exactly as before, so polling a
  live batch is unchanged.

  Written once, by the statement that already runs once per batch, rather than bumped from
  `complete!` and `fail!`. A per-job counter would serialise every worker in a batch behind a
  single row lock and churn a tuple per job, to speed up reads that were never on the hot path.
  The completion statement takes that lock anyway, and a terminal batch transitions no further
  jobs, so the tally cannot drift from the rows.

- `rails g sidekiq:batch:jobs:upgrade`, which replaces the copy-paste migration these notes
  used to hand you. It reads your tables and emits only what they are missing, so upgrading
  from 0.1.0 and upgrading from 0.2.0 are the same command and each writes the migration that
  applies. Nothing to do means no file, so it is safe to run against a current database, and
  safe to run twice. `Sidekiq::Batch::Jobs::Schema` is the schema it diffs against.

### Upgrading from 0.2.0

```bash
bin/rails g sidekiq:batch:jobs:upgrade
bin/rails db:migrate
```

Two nullable columns, which on Postgres 11+ is a metadata-only change however large the table.

Run it before the workers pick up the new code, not after. The completion statement names both
columns, so until they exist every completion check fails.

Nothing is lost if that order slips. The failure is caught where every completion check is
caught: the job itself still succeeds, the batch keeps its rows and stays `running`, and the
reason goes to `config.on_alert`. Once the columns exist, the next job to finish transitions
its batch normally, and `SidekiqBatch::ReaperWorker` completes any batch whose last job already
ran, once it has been quiet for `config.stuck_after` (two hours by default).

No backfill. NULL means "no tally was stamped", which is every running batch and every batch
that finished under 0.2.0; both fall back to counting job rows the way 0.2.0 always did.
Batches that finish after the migration carry their own counts.

## [0.2.0] - 2026-08-31

0.1.0 could enrol a batch, detect completion and fire a callback. This release keeps that core
and builds the rest of the gem around it: a maintenance layer that repairs batches nothing else
can reach, a failure policy you control, and a third callback event. It also renames the
callback vocabulary to match Sidekiq Pro's, which is the change most likely to affect you.

### Breaking

- **`:complete` now fires whatever the outcome.** In 0.1.0 it meant "all finished *and* all
  succeeded"; that meaning is now `:success`. If you registered `on(:complete, MyWorker)` as a
  success hook, it will start running on failed batches too, with nothing to warn you. Change
  those registrations to `on(:success, MyWorker)` to keep 0.1.0's behaviour.
- Batch status `complete` is now `succeeded`, so each terminal status names the event that
  fires with it. The stored integer is unchanged, so no data migration is needed, but code
  comparing `batch.status == "complete"` or calling `complete_status?` must be updated.
  `SidekiqBatchJob` statuses are untouched: a *job* that finished is still `complete`.
- `SidekiqBatch#fire_callback(event)` is gone, replaced by `#fire_callbacks`. A batch now
  announces two events at once, so firing one by hand would spend an announcement the batch has
  not finished making.
- `Sidekiq::Batch::Jobs.auto_install = false` and `.disable_auto_install!` are gone, along with
  `.reset_installed!`. Configure the gem through `Sidekiq::Batch::Jobs.configure` instead.
- A batch can only be enrolled once. A second `jobs { … }` block on the same batch raises
  `AlreadyStartedError` rather than enrolling into a batch whose `total_jobs` is already
  stamped. There is no reopening a batch the way Sidekiq Pro allows.
- **A migration is required.** See *Upgrading from 0.1.0* below.

### Added

- A configurable failure policy: `:any_failure` (the default, and what 0.1.0 always did),
  `:all_failed`, `{ tolerate: 10 }` or `{ tolerate: "5%" }`, per batch or globally through
  `config.failure_policy`. All four are the same rule with a different threshold, evaluated
  inside the same atomic statement that transitions the batch, so choosing one never costs a
  race. Nothing forgives a `jobs {}` block that died partway through enrolling: that batch
  fails whatever the policy, with the cause recorded in `enrollment_error`.
- A third callback event. `:complete` fires however the batch went, `:success` and `:failure`
  name the outcome and are mutually exclusive, so "always do X, and separately tell me when it
  went badly" is two registrations rather than one worker doing both. Each event's enqueue is
  claimed atomically and independently, so a callback that cannot be delivered never causes a
  redelivery of one that already went out. Delivery is at-least-once: the push shares a
  transaction with the claim, so a crash between the two rolls that claim back and the reaper
  re-enqueues. Write callbacks to be idempotent.
- `SidekiqBatch::ReaperWorker`, three recoveries in one pass: batches whose `jobs {}` block died
  mid-enrollment and left them `pending` forever, batches stalled by a job that vanished from
  Redis (SIGKILL, OOM, pod eviction, or **Kill All** on Sidekiq's Retries page, which moves jobs
  to the dead set without running death handlers), and callbacks orphaned by a crash between the
  completion `UPDATE` and the enqueue.
- `SidekiqBatch::GroomerWorker`, which deletes terminal batches past the retention window and
  long-abandoned `pending` ones as a backstop for hosts that do not run the reaper.
- `Sidekiq::Batch::Jobs.configure` for `base_class_name`, `stuck_after`, `retention`,
  `failure_policy`, `on_alert`, `maintenance_queue`, `error_message_max` and `auto_install`.
  `on_alert` is the gem's only unprompted signal; point it somewhere you read.
- `#percentage_progress`, `#eta` and `#terminal?` alongside the existing `#progress`.
- Rails 6.1 and Sidekiq 7 support. 0.1.0 required Ruby >= 3.2 and only worked on Rails 7+;
  0.2.0 runs on Ruby >= 3.0 and is tested against Rails 6.1, 7.1 and 8.0 with Sidekiq 7 and 8.

### Fixed

Found by a full audit of 0.1.0. Each fix has a spec that was confirmed to fail against the
old code.

- **A job's row could be marked failed on its first attempt.** `final_attempt?` compared
  `retry_count` against the wrong bound and read the worker class instead of the payload, so a
  `retry: false` worker pushed with `set(retry: 5)` failed its batch while Sidekiq went on to
  retry and succeed. Unrecoverable once it happened. The same bug made the middleware's
  failure path dead code for every retrying worker.
- **An exception or a crash inside `jobs { … }` stranded the batch in `pending` forever.**
  Its queued jobs ran, nothing ever announced, and neither the batch nor its rows were ever
  cleaned up. Ordinary exceptions are now recorded and the batch finished; a killed process is
  recovered by the reaper.
- **A batch's own callback could be enrolled into the batch it announces**, freezing
  `total_jobs` below the row count and leaving a `pending` row nothing would look at.
- **Reopening a batch deleted it.** A second `jobs { … }` block that enrolled nothing, or
  raised before its first push, destroyed the batch and every row tracking a job that was
  already running.
- **Every Sidekiq job in the host application ran a Postgres query**, batch-tracked or not.
  Untracked jobs now cost zero queries and have no Postgres coupling at all.
- **Enrollment cost five round trips per job**, two of which bought nothing. Now three, which
  is the floor.
- Enrolling inside an open transaction was only detected at the start of the block, and only
  on the default connection.
- `fire_callback` was public and consumed the batch's one announcement, so calling it early
  permanently suppressed the real callback.
- A bookkeeping failure could reach the caller as if their enqueue had failed, inviting a retry
  that enqueued the whole batch a second time; another could replace a job's own exception on
  its way to Sidekiq, misreporting why the job died.
- `batch.destroy` loaded and destroyed children one row at a time despite the FK already
  cascading.

### Upgrading from 0.1.0

Four columns and two indexes:

```ruby
class UpgradeSidekiqBatchTables < ActiveRecord::Migration[7.1]
  def change
    add_column :sidekiq_batches, :callbacks_fired,   :jsonb, null: false, default: {}
    add_column :sidekiq_batches, :failure_policy,    :string
    add_column :sidekiq_batches, :failure_tolerance, :integer
    add_column :sidekiq_batches, :enrollment_error,  :jsonb

    add_index    :sidekiq_batches,     [:status, :created_at]
    add_index    :sidekiq_batch_jobs,  :updated_at
    remove_index :sidekiq_batches,     :status
  end
end
```

The bare `:status` index goes because both composites lead with `status`, and Postgres serves a
status-only lookup from either. `sidekiq_batch_jobs.updated_at` is what stops the reaper
sequentially scanning the whole jobs table.

No data backfill. The status integers are unchanged, and existing rows keep a NULL
`failure_policy`, which the completion statement reads as `:any_failure`: exactly what 0.1.0
did. Batches that already announced under 0.1.0 have `callback_fired_at` set, so the new
orphaned-callback reaper leaves them alone.

Then re-read the `:complete` note under **Breaking** above. It is the one change that alters
behaviour without raising anything.

## [0.1.0] - 2026-05-13

First release. `batch.jobs { … }` enrollment with rows committed before their jobs reach Redis,
atomic completion detection, two callback events (`:complete` and `:failure`), `#progress`, a
`context` column, and client middleware, server middleware and a death handler wired up by the
Rails engine.
