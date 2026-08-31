# frozen_string_literal: true

require "spec_helper"

RSpec.describe SidekiqBatch::BatchEnrollmentContext do
  let(:batch) { create(:sidekiq_batch) }

  describe "#run" do
    it "enrolls every job pushed inside the block" do
      batch.jobs do
        SidekiqBatchTestWorker.perform_async(1)
        SidekiqBatchTestWorker.perform_async(2, 3)
      end

      expect(batch.reload.status).to eq("running")
      expect(batch.total_jobs).to eq(2)
      expect(batch.sidekiq_batch_jobs.pluck(:worker_class, :args)).to contain_exactly(
        ["SidekiqBatchTestWorker", [1]],
        ["SidekiqBatchTestWorker", [2, 3]]
      )
    end

    it "matches enrolled jids to the jids Sidekiq assigned to the pushed jobs" do
      batch.jobs do
        SidekiqBatchTestWorker.perform_async
        SidekiqBatchTestWorker.perform_async
      end

      enrolled = batch.sidekiq_batch_jobs.pluck(:jid).sort
      pushed   = SidekiqBatchTestWorker.jobs.map { |j| j["jid"] }.sort

      expect(enrolled).to eq(pushed)
      expect(enrolled).to all(be_present)
    end

    it "enrolls bulk pushes (push_bulk / perform_bulk)" do
      batch.jobs do
        SidekiqBatchTestWorker.perform_bulk([[1], [2], [3]])
      end

      expect(batch.sidekiq_batch_jobs.count).to eq(3)
      expect(batch.total_jobs).to eq(3)
    end

    it "raises when the block is empty and destroys the orphan batch" do
      expect do
        batch.jobs {}
      end.to raise_error(described_class::EmptyEnrollmentError)

      expect(SidekiqBatch.exists?(batch.id)).to be(false)
    end

    # Sidekiq Pro lets you reopen a batch and add more jobs, so someone
    # migrating will try it. Here the second block reached disposal paths that
    # assume a fresh `pending` batch: an empty one destroyed a live batch and
    # every row tracking its running jobs, and the completion check for those
    # jobs then matched nothing.
    describe "when the batch has already been enrolled" do
      before { batch.jobs { SidekiqBatchTestWorker.perform_async(1) } }

      it "rejects a second block instead of enrolling into a started batch" do
        expect { batch.jobs { SidekiqBatchTestWorker.perform_async(2) } }
          .to raise_error(described_class::AlreadyStartedError, /already run for SidekiqBatch ##{batch.id}/)

        expect(batch.reload.total_jobs).to eq(1)
        expect(SidekiqBatchTestWorker.jobs.size).to eq(1)
      end

      it "keeps the batch and its rows when the second block enrolls nothing" do
        expect { batch.jobs {} }.to raise_error(described_class::AlreadyStartedError)

        expect(batch.reload.status).to eq("running")
        expect(batch.sidekiq_batch_jobs.count).to eq(1)
      end

      it "keeps them when the second block raises before enrolling anything" do
        expect { batch.jobs { raise "caller boom" } }.to raise_error(described_class::AlreadyStartedError)

        expect(SidekiqBatch.exists?(batch.id)).to be(true)
        expect(batch.sidekiq_batch_jobs.count).to eq(1)
      end

      it "rejects one on a batch that has already finished and announced" do
        batch.sidekiq_batch_jobs.first.mark_complete!
        batch.attempt_completion!

        expect { batch.jobs {} }.to raise_error(described_class::AlreadyStartedError, /succeeded/)

        expect(SidekiqBatch.exists?(batch.id)).to be(true)
      end
    end

    it "raises when called inside a caller-opened transaction" do
      expect do
        ActiveRecord::Base.transaction do
          batch.jobs { SidekiqBatchTestWorker.perform_async }
        end
      end.to raise_error(described_class::TransactionError)
    end

    # The entry check only sees a transaction the caller had already opened. One
    # opened inside the block leaves the row uncommitted while raw_push has
    # already handed the job to Redis — the worker can start before its row is
    # visible, or a rollback can discard the row for a job that ran.
    it "raises when a transaction is opened inside the block" do
      expect do
        batch.jobs do
          SidekiqBatchTestWorker.perform_async(1)
          ActiveRecord::Base.transaction { SidekiqBatchTestWorker.perform_async(2) }
        end
      end.to raise_error(described_class::TransactionError)
    end

    it "raises when a nested jobs {} block is attempted" do
      expect do
        batch.jobs do
          SidekiqBatchTestWorker.perform_async
          create(:sidekiq_batch).jobs { SidekiqBatchTestWorker.perform_async }
        end
      end.to raise_error(described_class::NestedError)
    end

    it "leaves the outer context intact when a rescued nested block is attempted" do
      # The nested call raises before it ever registers itself, so unwinding it
      # must not clear the key the outer block is still relying on — otherwise
      # every push after the rescue is silently un-enrolled.
      batch.jobs do
        SidekiqBatchTestWorker.perform_async(1)

        begin
          create(:sidekiq_batch).jobs { SidekiqBatchTestWorker.perform_async }
        rescue described_class::NestedError
          nil
        end

        SidekiqBatchTestWorker.perform_async(2)
      end

      expect(batch.reload.total_jobs).to eq(2)
      expect(batch.sidekiq_batch_jobs.pluck(:args)).to contain_exactly([1], [2])
    end

    it "clears the thread-local context even on error" do
      expect do
        batch.jobs do
          SidekiqBatchTestWorker.perform_async
          raise "caller boom"
        end
      end.to raise_error("caller boom")

      expect(described_class.current).to be_nil
    end

    it "does not enroll perform_async calls made outside any jobs block" do
      SidekiqBatchTestWorker.perform_async(99)

      expect(SidekiqBatchJob.count).to eq(0)
    end

    it "enrolls a job in one INSERT, with no supporting lookups" do
      # Scoped to the push itself — the block's own bookkeeping (row count,
      # status update, completion check) is not what this pins down. Enrollment
      # runs synchronously on the enqueuing thread, once per job, so a stray
      # SELECT here is paid by whoever is filling the batch.
      queries = []

      batch.jobs { queries = queries_made { SidekiqBatchTestWorker.perform_async(1) } }

      expect(queries.grep(/\ASELECT/)).to be_empty
      expect(queries.grep(/\AINSERT/).size).to eq(1)
    end

    describe "the batch id stamped into the payload" do
      let(:key) { SidekiqBatch::PAYLOAD_BATCH_ID_KEY }

      it "reaches the payload Sidekiq pushes" do
        batch.jobs { SidekiqBatchTestWorker.perform_async(1) }

        expect(SidekiqBatchTestWorker.jobs.last[key]).to eq(batch.id)
      end

      it "reaches every payload of a bulk push" do
        batch.jobs { SidekiqBatchTestWorker.perform_bulk([[1], [2], [3]]) }

        expect(SidekiqBatchTestWorker.jobs.map { |job| job[key] }).to eq([batch.id] * 3)
      end

      it "is absent from jobs pushed outside a block" do
        SidekiqBatchTestWorker.perform_async(99)

        expect(SidekiqBatchTestWorker.jobs.last).not_to have_key(key)
      end

      # The round trip is the actual contract: whatever the client middleware
      # pushed has to be enough for the server middleware to track the job with
      # no lookup of its own.
      it "is enough for the server middleware to track the job end to end" do
        batch.jobs { SidekiqBatchTestWorker.perform_async(1) }

        payload = SidekiqBatchTestWorker.jobs.last

        SidekiqBatch::Middleware.new.call(SidekiqBatchTestWorker.new, payload, "default") { nil }

        expect(batch.sidekiq_batch_jobs.first.status).to eq("complete")
        expect(batch.reload.status).to eq("succeeded")
      end
    end

    it "fires the complete callback immediately when no work actually runs (fast-finish race)" do
      # Simulate the race: jobs already "finished" before the block closes by
      # marking every enrolled row complete from within the block. When the
      # block closes, attempt_completion! must fire the callback — otherwise
      # the batch is stuck (no future worker will trigger the check).
      batch.on(:complete, SidekiqBatchTestFanInJob)

      batch.jobs do
        SidekiqBatchTestWorker.perform_async
        SidekiqBatchJob.update_all(status: SidekiqBatchJob.statuses.fetch("complete"))
      end

      expect(batch.reload.status).to eq("succeeded")
      expect(SidekiqBatchTestFanInJob.jobs.size).to eq(1)
    end

    it "does not enroll the callback it fires on the fast-finish race" do
      # Same race as above, but the point here is the push attempt_completion!
      # makes on the way out. Enrollment is over once the block returns, so the
      # callback must not become a member of the batch it announces — that
      # would leave total_jobs short of the row count and strand a `pending`
      # row on a batch the stuck-job reaper no longer looks at.
      batch.on(:complete, SidekiqBatchTestFanInJob)

      batch.jobs do
        SidekiqBatchTestWorker.perform_async
        SidekiqBatchJob.update_all(status: SidekiqBatchJob.statuses.fetch("complete"))
      end

      expect(batch.reload.total_jobs).to eq(1)
      expect(batch.sidekiq_batch_jobs.pluck(:worker_class)).to eq(["SidekiqBatchTestWorker"])
    end

    # H2. A block that raises after some pushes used to re-raise with the batch
    # still `pending` — a state StuckJobReaper (running only) and RecordGroomer
    # (terminal only) both ignore, so the queued jobs ran, nothing was ever
    # announced, and the rows sat there for the life of the table.
    describe "when the block raises partway through" do
      def enroll_then_raise(count: 1, error: RuntimeError.new("caller boom"))
        batch.jobs do
          count.times { |i| SidekiqBatchTestWorker.perform_async(i) }

          raise error
        end
      end

      it "still raises the caller's own error" do
        expect { enroll_then_raise }.to raise_error("caller boom")
      end

      it "records what broke enrollment" do
        expect { enroll_then_raise(error: ArgumentError.new("bad row")) }.to raise_error(ArgumentError)

        expect(batch.reload.enrollment_error).to eq("class" => "ArgumentError", "message" => "bad row")
      end

      it "starts the batch, so the jobs it did queue are still tracked" do
        expect { enroll_then_raise(count: 3) }.to raise_error("caller boom")

        expect(batch.reload.status).to eq("running")
        expect(batch.total_jobs).to eq(3)
      end

      it "truncates a runaway error message rather than storing all of it" do
        Sidekiq::Batch::Jobs.configure { |c| c.error_message_max = 20 }

        expect { enroll_then_raise(error: RuntimeError.new("x" * 500)) }.to raise_error(RuntimeError)

        expect(batch.reload.enrollment_error["message"].length).to eq(20)
      end

      # Nothing was queued, so there is nothing to announce and nothing to leak.
      it "destroys the batch when it raised before enrolling anything" do
        expect { batch.jobs { raise "boom before any push" } }.to raise_error("boom before any push")

        expect(SidekiqBatch.exists?(batch.id)).to be(false)
      end

      it "lands failed once the queued jobs finish, whatever the policy tolerates" do
        tolerant = create(:sidekiq_batch, failure_policy: { tolerate: "100%" })

        expect do
          tolerant.jobs do
            SidekiqBatchTestWorker.perform_async
            SidekiqBatchJob.update_all(status: SidekiqBatchJob.statuses.fetch("complete"))

            raise "caller boom"
          end
        end.to raise_error("caller boom")

        expect(tolerant.reload.status).to eq("failed")
      end

      # The regression guard for H1 on this path. Ruby runs a rescue clause
      # before the ensure in the same begin, so a rescue written beside the
      # yield would push these callbacks with the context still active and
      # enroll them into the batch they announce.
      it "does not enroll the callbacks it fires while unwinding" do
        batch.on(:complete, SidekiqBatchTestAlwaysJob)
        batch.on(:failure, SidekiqBatchTestFailureJob)

        expect do
          batch.jobs do
            SidekiqBatchTestWorker.perform_async
            SidekiqBatchJob.update_all(status: SidekiqBatchJob.statuses.fetch("complete"))

            raise "caller boom"
          end
        end.to raise_error("caller boom")

        expect(batch.reload.status).to eq("failed")
        expect(batch.total_jobs).to eq(1)
        expect(batch.sidekiq_batch_jobs.pluck(:worker_class)).to eq(["SidekiqBatchTestWorker"])
        expect(SidekiqBatchTestAlwaysJob.jobs.size).to eq(1)
        expect(SidekiqBatchTestFailureJob.jobs.size).to eq(1)
      end

      # The caller's exception explains what actually went wrong; a failure to
      # write it down must not take its place.
      it "keeps the caller's exception when recording the failure fails too" do
        alerts                                          = []
        Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(message) { alerts << message } }
        allow(batch).to receive(:attempt_completion!).and_raise(ActiveRecord::StatementInvalid, "pg gone")

        expect { enroll_then_raise }.to raise_error("caller boom")
        expect(alerts.join).to include("##{batch.id}", "pg gone")
      end

      # A guard that fires at entry rejected the call outright; nothing was
      # enrolled and the batch must be left exactly as the caller left it.
      it "leaves the batch alone when a guard rejected the block before it ran" do
        batch # created out here, so the rollback below cannot take it with it

        expect do
          ActiveRecord::Base.transaction { batch.jobs { SidekiqBatchTestWorker.perform_async } }
        end.to raise_error(described_class::TransactionError)

        expect(batch.reload).to have_attributes(status: "pending", enrollment_error: nil)
      end
    end

    # The reaper can declare a long-quiet `pending` batch abandoned and start it
    # itself. Overwriting that would flip an already-terminal batch back to
    # `running` with its claim spent — completing a second time, losing the
    # claim race, and losing its callbacks with no trace for the orphan reaper.
    it "raises rather than clobbering a batch the reaper adopted mid-block" do
      expect do
        batch.jobs do
          SidekiqBatchTestWorker.perform_async

          SidekiqBatch.where(id: batch.id)
                      .update_all(status: SidekiqBatch.statuses.fetch("running"))
        end
      end.to raise_error(described_class::AdoptedError, /reaped as abandoned/)
    end

    # Everything the caller asked for has happened by this point: the rows are
    # committed and the jobs are queued. Reporting a bookkeeping failure as an
    # enqueue failure invites a retry that pushes the whole batch a second time.
    describe "when the completion check after the block fails" do
      before do
        Sidekiq::Batch::Jobs.configure { |c| c.on_alert = ->(message) { alerts << message } }
        allow(batch).to receive(:attempt_completion!).and_raise(ActiveRecord::StatementInvalid, "pg gone")
      end

      let(:alerts) { [] }

      it "does not tell the caller their enqueue failed" do
        expect { batch.jobs { SidekiqBatchTestWorker.perform_async } }.not_to raise_error
      end

      it "leaves the batch running with its jobs tracked, for the reaper to finish" do
        batch.jobs { SidekiqBatchTestWorker.perform_async }

        expect(batch.reload).to have_attributes(status: "running", total_jobs: 1)
      end

      it "alerts instead" do
        batch.jobs { SidekiqBatchTestWorker.perform_async }

        expect(alerts.join).to include("##{batch.id}", "pg gone")
      end
    end

    # A batch left `pending` is genuinely degraded: nothing has stamped
    # total_jobs, and the reaper will eventually adopt it and mark the whole
    # thing failed. That the caller must hear about.
    it "still raises when the batch could not be started at all" do
      allow(SidekiqBatch).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "pg gone")

      expect { batch.jobs { SidekiqBatchTestWorker.perform_async } }
        .to raise_error(ActiveRecord::StatementInvalid)
    end

    it "clears the thread-local context before the post-block bookkeeping runs" do
      seen = :not_captured

      batch.on(:complete, SidekiqBatchTestFanInJob)
      allow(batch).to receive(:attempt_completion!).and_wrap_original do |original, *args|
        seen = described_class.current
        original.call(*args)
      end

      batch.jobs { SidekiqBatchTestWorker.perform_async }

      expect(seen).to be_nil
    end
  end
end
