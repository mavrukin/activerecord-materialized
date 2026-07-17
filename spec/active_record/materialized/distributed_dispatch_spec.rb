# frozen_string_literal: true

require "spec_helper"
require "logger"
require "active_job"
require "activerecord/materialized/refresh_job"
require "activerecord/materialized/reconcile_job"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are satisfied.
module DistributedDispatch; end

# #93 (distribution-correct dispatch + reconcile fan-out) — a scheduled tick enqueues one
# background job per stale, materialized view so a fleet shares the work, instead of one process
# doing it serially. Views use refresh_on_change :manual so seeding/rebuild never dispatches on its
# own; staleness is set explicitly, isolating the fan-out behavior under test.
RSpec.describe DistributedDispatch do
  let(:stale_view) { define_view("mv_dispatch_stale", :item_count_by_category) { refresh_on_change :manual } }
  let(:fresh_view) { define_view("mv_dispatch_fresh", :item_count_by_category) { refresh_on_change :manual } }
  let(:cold_view) { define_view("mv_dispatch_cold", :item_count_by_category) { refresh_on_change :manual } }
  let(:enqueued) { ActiveJob::Base.queue_adapter.enqueued_jobs }

  around do |example|
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  before do
    stale_view
    fresh_view
    cold_view # registered but never rebuilt => cold (stale by never-refreshed, yet read-through)
    seed_items(["books", 1], ["games", 2])
    [stale_view, fresh_view].each { |view| view.rebuild!(confirm: true) } # warm; cold_view left cold
    stale_view.metadata.mark_dirty! # only this warm view is stale
  end

  describe ".enqueue_stale_reconciles!" do
    it "enqueues one ReconcileJob per stale materialized view (skipping fresh and cold ones)" do
      keys = nil
      expect { keys = ActiveRecord::Materialized.enqueue_stale_reconciles! }.to change(enqueued, :size).by(1)

      # fresh_view isn't stale; cold_view is stale but never materialized (a job would only no-op).
      expect(keys).to contain_exactly(stale_view.view_key)
      job = enqueued.last
      expect(job[:job]).to eq(ActiveRecord::Materialized::ReconcileJob)
      expect(job[:args]).to include(stale_view.view_key)
    end

    it "raises a clear error, not a NameError, when ActiveJob is unavailable" do
      allow(ActiveRecord::Materialized.configuration).to receive(:active_job_available?).and_return(false)

      expect { ActiveRecord::Materialized.enqueue_stale_reconciles! }
        .to raise_error(NotImplementedError, /requires ActiveJob/)
    end
  end

  describe ".enqueue_stale_refreshes!" do
    it "enqueues one RefreshJob per stale materialized view (fan-out form of the serial pass)" do
      keys = nil
      expect { keys = ActiveRecord::Materialized.enqueue_stale_refreshes! }.to change(enqueued, :size).by(1)

      expect(keys).to contain_exactly(stale_view.view_key)
      expect(enqueued.last[:job]).to eq(ActiveRecord::Materialized::RefreshJob)
    end
  end

  describe ActiveRecord::Materialized::ReconcileJob do
    it "reconciles a still-stale view but no-ops one the fleet already made fresh" do
      # Still stale => the job runs reconcile!, stamping the reconciliation clock.
      expect { described_class.perform_now(stale_view.view_key) }
        .to change { stale_view.metadata.record.last_reconciled_at }.from(nil)

      # No longer stale (another server handled it) => the job skips the expensive verification.
      expect { described_class.perform_now(fresh_view.view_key) }
        .not_to(change { fresh_view.metadata.record.last_reconciled_at })
    end
  end

  describe ".warn_if_in_process_dispatcher!" do
    it "warns when ActiveJob is loaded but dispatch is in-process, and is silent for :active_job" do
      logger = instance_spy(Logger)
      config = ActiveRecord::Materialized.configuration

      config.refresh_dispatcher = :async # ActiveJob is loaded in this suite, but dispatch is in-process
      ActiveRecord::Materialized.warn_if_in_process_dispatcher!(logger: logger)
      config.refresh_dispatcher = :active_job
      ActiveRecord::Materialized.warn_if_in_process_dispatcher!(logger: logger)

      expect(logger).to have_received(:warn).once.with(/single-process-only/)
    end
  end
end
