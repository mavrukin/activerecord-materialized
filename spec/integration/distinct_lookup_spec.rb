# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module DistinctLookup
  # Distinct-lookup view: SELECT DISTINCT category (no GROUP BY, no aggregate) — its projected
  # column is the partition key, exactly like `group(:category)`, so it is scoped-recompute
  # maintained rather than full-refresh-only. Callback-fed, manual refresh to drive it explicitly.
  def self.define_view(table_name)
    IntegrationSchema.build_view(
      table_name, :arm_line_items,
      changes: :callbacks, source: -> { IntegrationSchema::LineItem.distinct.select(:category) }
    ) { refresh_on_change :manual }
  end
end

# A DISTINCT projection without GROUP BY (`SELECT DISTINCT category`) is the
# canonical "distinct lookup" the gem exists to speed up. It partitions
# identically to `GROUP BY category` (no aggregates), so it is maintained
# incrementally through the scoped-recompute path rather than degrading to
# full-refresh-only. This exercises the full lifecycle — build, scoped write,
# read — on every configured engine.
RSpec.describe DistinctLookup, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before { with_adapter!(profile) }

      it "builds, then scoped-maintains a new distinct value on write, and converges", :aggregate_failures do
        view = described_class.define_view("mv_distinct_categories")
        IntegrationSchema::LineItem.create!(category: "books", amount: 10)
        IntegrationSchema::LineItem.create!(category: "books", amount: 20) # duplicate collapses
        IntegrationSchema::LineItem.create!(category: "games", amount: 5)

        view.rebuild!(confirm: true)
        expect(view.order(:category).pluck(:category)).to eq(%w[books games])
        expect(converged?(view)).to be(true)

        # A write introducing a brand-new distinct value schedules scoped maintenance
        # for exactly that partition — not a full recompute of the whole table.
        IntegrationSchema::LineItem.create!(category: "music", amount: 7)
        pending = ActiveRecord::Materialized::MaintenanceStore.new(view).pending
        expect(pending.full_partition?).to be(false)
        expect(pending.key_tuples).to eq([["music"]])

        view.refresh!
        expect(view.order(:category).pluck(:category)).to eq(%w[books games music])
        expect(converged?(view)).to be(true)
      end

      it "serves correct read-through results before it is built" do
        view = described_class.define_view("mv_distinct_cold")
        IntegrationSchema::LineItem.create!(category: "books", amount: 10)
        IntegrationSchema::LineItem.create!(category: "books", amount: 20)

        # Cold (unbuilt) view reads through to the DISTINCT source: correct, de-duplicated.
        expect(view.materialized?).to be(false)
        expect(view.pluck(:category)).to eq(["books"])
      end
    end
  end
end
