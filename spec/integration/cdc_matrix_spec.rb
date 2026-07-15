# frozen_string_literal: true

require_relative "integration_helper"

# #70 — the real-DB integration matrix. For each configured adapter (SQLite in
# process; MySQL/Postgres via ARM_* env / Docker Compose) it drives the #71
# CdcScenario against a real connection: a raw INSERT bypasses callbacks, is
# relayed through ingest_change, and the view must converge via SCOPED
# maintenance — proving write→ingest→maintain→read and DDL/type portability.
# Unavailable adapters are skipped with a logged reason (never silently).
module CdcMatrix; end

RSpec.describe CdcMatrix, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before { with_adapter!(profile) }

      let(:view) { IntegrationSchema.define_view("mv_line_items_by_category") }

      it "converges via scoped maintenance from a raw write relayed through ingest_change" do
        seed_line_items(["books", 1], ["games", 1]) # item_count 1 per category
        view.rebuild!(confirm: true)

        run = BenchmarkSupport::CdcScenario.new(view: view, raw_write: lambda {
          IntegrationSchema::LineItem.connection.execute(
            "INSERT INTO arm_line_items (category, amount) VALUES ('books', 5)"
          )
          { table: "arm_line_items", operation: :create, key_attributes: { "category" => "books" } }
        }).run

        # the cache matches the freshly-computed source on the real engine...
        expect(run.converged?).to be(true)
        expect(view.where(category: "books").pick(:item_count)).to eq(2)
        # ...via partition-scoped maintenance, observed through the real event
        expect(run.scoped?).to be(true)
        expect(run.timeline.find { |event| event.stage == :maintenance }.payload).to include(scope: :scoped)
      end

      it "rebuilds a portable cache table matching the source (DDL + type inference)" do
        seed_line_items(["books", 3], ["games", 7], ["books", 4]) # books sum 7; games sum 7
        view.rebuild!(confirm: true)

        # create_table + INSERT…SELECT (+ atomic swap on a warm table) ran on the
        # real engine, and the materialized rows equal the source relation.
        cache = view.unscoped.to_a
        source = view.resolved_source.to_a
        expect(BenchmarkSupport::ResultComparison.equivalent?(cache, source)).to be(true)
        expect(view.where(category: "books").pick(:total_amount)).to eq(7)
      end
    end
  end
end
