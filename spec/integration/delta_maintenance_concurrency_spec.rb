# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module DeltaMaintenanceConcurrency; end

# #75 (cross-process cycle lock) — the non-idempotent summary-delta path must be serialized
# across connections so a pending additive delta is applied exactly once. This exercises the
# real FOR UPDATE lock deterministically: one connection holds the cycle lock while another
# tries to run a cycle, which must defer without consuming the delta (so it can't double-apply);
# once the lock frees, the queued delta applies once and the view converges. Runs on MySQL and
# Postgres; SQLite is skipped (no row-level FOR UPDATE — it serializes writers at the database
# level, so there is no cross-connection lock to hold).
RSpec.describe DeltaMaintenanceConcurrency, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        skip("SQLite has no row-level FOR UPDATE lock (single-writer database)") if profile.key == :sqlite
        with_adapter!(profile)
      end

      it "makes a concurrent summary-delta cycle defer without consuming the delta" do
        view = IntegrationSchema.define_delta_view("mv_delta_lock")
        IntegrationSchema.bulk_seed_line_items(20)
        view.rebuild!(confirm: true)
        IntegrationSchema::LineItem.create!(category: "cat-0", sku: "x", amount: 10) # pending additive +delta
        store = ActiveRecord::Materialized::MaintenanceStore.new(view)

        holding_the_cycle_lock(view) do
          # A concurrent cycle can't acquire the lock, so it defers — and crucially does NOT consume
          # the delta (without the lock it would consume+apply it, racing into a double-apply).
          expect { view.refresh! }.to raise_error(ActiveRecord::Materialized::Refresher::AlreadyRefreshingError)
          expect(store.pending).not_to be_nil # the additive delta is still queued, un-applied
        end

        view.refresh! # lock free: the queued delta drains exactly once
        expect(converged?(view)).to be(true) # cache matches the source — applied once
      end

      # Hold the view's cycle lock on a background connection for the duration of the block, so the
      # yielded code runs while another connection genuinely owns the metadata-row FOR UPDATE lock.
      def holding_the_cycle_lock(view)
        locked = Queue.new
        release = Queue.new
        holder = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            view.metadata.record.with_lock("FOR UPDATE NOWAIT") do
              locked << :held
              release.pop
            end
          end
        end
        locked.pop # the holder now owns the lock
        yield
      ensure
        release << :go # always free the holder, so a failed assertion fails cleanly (no leaked thread)
        holder.join
      end
    end
  end
end
