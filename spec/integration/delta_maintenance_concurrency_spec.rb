# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module DeltaMaintenanceConcurrency; end

# #75 (cross-process cycle lock) — the non-idempotent summary-delta consume+apply is serialized
# across connections by a row lock on the metadata row (MaintenanceStore#with_consumed_summary_delta),
# so a pending additive delta is applied exactly once. Two connections race the consume: the lock lets
# one consume+apply it while the other blocks, then reads an empty payload and no-ops. Runs on MySQL
# and Postgres; SQLite is skipped (no row-level FOR UPDATE — it serializes writers at the database
# level, so there is no cross-connection race to exercise).
RSpec.describe DeltaMaintenanceConcurrency, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        skip("SQLite has no row-level FOR UPDATE lock (single-writer database)") if profile.key == :sqlite
        with_adapter!(profile)
      end

      it "consumes+applies a summary delta exactly once across concurrent connections" do
        view = IntegrationSchema.define_delta_view("mv_delta_race")
        IntegrationSchema.bulk_seed_line_items(20)
        view.rebuild!(confirm: true)
        IntegrationSchema::LineItem.create!(category: "cat-0", sku: "x", amount: 10) # pending additive +delta
        store = ActiveRecord::Materialized::MaintenanceStore.new(view)

        # Race two connections through the atomic consume+apply; each returns the delta it consumed,
        # or nil if the other connection had already taken it.
        winners = race_connections(2) do
          store.with_consumed_summary_delta do |delta|
            ActiveRecord::Materialized::DeltaMaintainer.new(view).apply!(delta)
            delta
          end
        end.compact

        expect(winners.size).to eq(1)        # exactly one connection consumed the delta; the other no-op'd
        expect(converged?(view)).to be(true) # it was applied once — the cache matches the source
      end
    end
  end
end
