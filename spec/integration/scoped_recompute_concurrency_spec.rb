# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module ScopedRecomputeConcurrency; end

# #95 — the scoped-recompute path (delete-partition + re-aggregate) is serialized across connections
# by an atomic consume of the pending delta: MaintenanceStore#consume_pending_delta! takes a row lock
# on the metadata row to read-and-clear, so two cross-process cycles can't both consume it and
# recompute the same brand-new partition — which duplicated rows on Postgres (no unique constraint,
# no gap locks under READ COMMITTED). The loser reads an empty payload and no-ops. Runs on MySQL and
# Postgres; SQLite serializes writers at the database level (skipped).
RSpec.describe ScopedRecomputeConcurrency, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        skip("SQLite serializes writers at the database level — no cross-connection race") if profile.key == :sqlite
        with_adapter!(profile)
      end

      it "consumes+applies a scoped delta exactly once across concurrent connections" do
        view = IntegrationSchema.define_scoped_view("mv_scoped_race") { refresh_on_change :manual }
        IntegrationSchema.bulk_seed_line_items(20)
        view.rebuild!(confirm: true)
        # A brand-new partition the cache does not hold — the exact case that duplicated pre-#95. The
        # :manual view records the write's scoped delta without applying it, leaving it pending.
        IntegrationSchema::LineItem.create!(category: "brand-new", sku: "x", amount: 10)
        # Two connections race the real maintenance path: the winner's atomic consume takes the
        # scoped delta and recomputes the partition; the loser consumes nil and hits maintain!'s
        # no-op branch. (Drives the shipped IncrementalMaintainer#maintain!, not a hand-rolled copy.)
        race_connections(2) do
          ActiveRecord::Materialized::IncrementalMaintainer.new(view).maintain!(view.connection, view.table_name)
        end

        expect(view.unscoped.where(category: "brand-new").count).to eq(1) # applied once — no duplicate row
        expect(converged?(view)).to be(true)                              # the cache matches the source
      end
    end
  end
end
