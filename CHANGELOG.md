# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
