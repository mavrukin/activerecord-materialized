# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module LoadBearing
  # Cache-column type groups for the metrics view — constants so the assertion isn't a
  # fresh array literal per adapter iteration (Performance/CollectionLiteralInLoop).
  INTEGER_COLUMNS = %w[item_count min_amount max_amount sku_count].freeze
  DECIMAL_COLUMNS = %w[total_amount avg_amount].freeze
end

# #84 — load-bearing single-process scenarios on every configured engine: a variety
# of aggregate shapes, mutations, and volume, asserting the view converges to the
# freshly-computed source. Also confirms #82 (engine-portable type inference) and
# #81 (rebuild/atomic swap) on the real engine. Unavailable adapters skip with a
# logged reason; an ARM_ONLY-targeted one fails instead.
RSpec.describe LoadBearing, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before { with_adapter!(profile) }

      it "converges under a variety of mutations at volume" do
        view = IntegrationSchema.define_view("mv_load")
        IntegrationSchema.bulk_seed_line_items(1_200) # ~100 categories, ~250 skus
        view.rebuild!(confirm: true)
        expect(converged?(view)).to be(true)

        # a create, a partition-moving update, and a callback-bypassing bulk delete —
        # each relayed through the ingestion API — leave the view converged
        IntegrationSchema::LineItem.create!(category: "cat-1", sku: "sku-x", amount: 99)
        relay("arm_line_items", :create, key_attributes: { "category" => "cat-1" })
        IntegrationSchema::LineItem.where(category: "cat-2").first.update!(category: "cat-3")
        relay("arm_line_items", :update, before: { "category" => "cat-2" }, after: { "category" => "cat-3" })
        IntegrationSchema::LineItem.where(category: "cat-4").delete_all
        relay("arm_line_items", :destroy, key_attributes: { "category" => "cat-4" })

        expect(converged?(view)).to be(true)
      end

      it "infers engine-appropriate types and exact values for every aggregate shape" do
        IntegrationSchema.bulk_seed_line_items(60)
        # controlled rows: a fractional average (1, 2 -> 1.5) and an INT-overflowing sum
        # (3e9). Before #82's fix these shipped silently wrong — a bare DECIMAL(10,0)
        # rounds 1.5 -> 2, and a 4-byte INT SUM column overflows at 3e9.
        IntegrationSchema::LineItem.create!(category: "frac-avg", amount: 1)
        IntegrationSchema::LineItem.create!(category: "frac-avg", amount: 2)
        3.times { IntegrationSchema::LineItem.create!(category: "big-sum", amount: 1_000_000_000) }
        view = IntegrationSchema.define_metrics_view("mv_metrics")
        view.rebuild!(confirm: true)
        types = view.columns_hash.transform_values(&:type)

        # COUNT(*)/MIN/MAX(int)/COUNT(DISTINCT) are integers; SUM and AVG are decimals
        # (MySQL widens SUM(int) to DECIMAL; an average carries fractional digits) — the
        # same types on every engine (was engine-divergent / all-:string before #82)
        expect(LoadBearing::INTEGER_COLUMNS.map { |name| types[name] }).to all(eq(:integer))
        expect(LoadBearing::DECIMAL_COLUMNS.map { |name| types[name] }).to all(eq(:decimal))

        # and the values are exact — not truncated by DECIMAL(10,0) or lost to INT overflow
        expect(view.where(category: "frac-avg").pick(:avg_amount)).to eq(1.5)
        expect(view.where(category: "big-sum").pick(:total_amount)).to eq(3_000_000_000)
      end

      it "scopes maintenance to the resolved partition for a joined leaf-table write" do
        country_view = IntegrationSchema.define_pages_by_country_view("mv_pages")
        aa = IntegrationSchema::Author.create!(country: "AA")
        bb = IntegrationSchema::Author.create!(country: "BB")
        IntegrationSchema::Book.create!(author: aa, pages: 100)
        IntegrationSchema::Book.create!(author: bb, pages: 50)
        country_view.rebuild!(confirm: true)

        book = IntegrationSchema::Book.create!(author: aa, pages: 25) # AA grows out-of-band
        relay("arm_books", :create, key_attributes: { "author_id" => book.author_id })

        expect(country_view.where(country: "AA").pick(:total_pages)).to eq(125)
        expect(country_view.where(country: "BB").pick(:total_pages)).to eq(50) # untouched
      end
    end
  end
end
