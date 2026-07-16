# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module DeltaMaintenanceConcurrency; end

# #75 (cross-process cycle lock) — the non-idempotent summary-delta path under concurrent
# refresh cycles. Several connections race to consume+apply the same pending additive delta; the
# real FOR UPDATE lock must let exactly one apply it while the rest defer, so the aggregate is
# never double-applied. Runs on MySQL and Postgres; SQLite is skipped (no row-level FOR UPDATE —
# it serializes writers at the database level, so there is no cross-connection race to exercise).
RSpec.describe DeltaMaintenanceConcurrency, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        skip("SQLite has no row-level FOR UPDATE lock (single-writer database)") if profile.key == :sqlite
        with_adapter!(profile)
      end

      it "applies each summary delta exactly once under concurrent refresh cycles" do
        view = IntegrationSchema.define_delta_view("mv_delta_race")
        IntegrationSchema.bulk_seed_line_items(100)
        view.rebuild!(confirm: true)

        # Each create! accumulates one additive +delta (callback-fed, manually refreshed); several
        # connections then race to consume it. With the lock exactly one applies it and the rest
        # defer, so repeating never inflates the SUM/COUNT past a single application.
        15.times do
          IntegrationSchema::LineItem.create!(category: "cat-0", sku: "race", amount: 10)
          race_to_refresh(view, connections: 3)
        end
        view.refresh! # drain a final deferred delta, if any

        expect(converged?(view)).to be(true) # cache SUM/COUNT equal the source — no double-application
      end

      # Release N connections into refresh! together so their maintenance cycles collide on the delta.
      def race_to_refresh(view, connections:)
        gate = Queue.new
        threads = Array.new(connections) do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              gate.pop # wait for the go signal so the cycles overlap
              view.refresh!
            rescue ActiveRecord::Materialized::Refresher::AlreadyRefreshingError
              nil # a concurrent cycle owns the lock; deferring is correct — the delta drains elsewhere
            end
          end
        end
        connections.times { gate << :go }
        threads.each(&:join)
      end
    end
  end
end
