# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Refresher do
  let(:view_class) { define_view("mv_sales_summary", :sales_by_category) }

  before { seed_items(["books", 10], ["books", 5], ["games", 20]) }

  describe "#rebuild!" do
    it "materializes query results into the cache table" do
      result = described_class.new(view_class).rebuild!

      expect(result.row_count).to eq(2)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq([
                                                                                  ["books", 15],
                                                                                  ["games", 20]
                                                                                ])
    end

    it "marks the view warm and records metadata" do
      travel_to Time.zone.local(2026, 1, 15, 12, 0, 0) do
        described_class.new(view_class).rebuild!
        expect(view_class.warm?).to be(true)
        expect(view_class.last_refreshed_at).to eq(Time.zone.local(2026, 1, 15, 12, 0, 0))
        expect(view_class.metadata.row_count).to eq(2)
        expect(view_class.metadata.refreshing?).to be(false)
      end
    end

    it "runs refresh callbacks" do
      events = []
      view_class.before_refresh { events << :before }
      view_class.after_refresh { events << :after }

      described_class.new(view_class).rebuild!
      expect(events).to eq(%i[before after])
    end
  end

  describe "#refresh!" do
    it "is a no-op on a cold view (never builds)" do
      result = described_class.new(view_class).refresh!

      expect(result.skipped).to be(true)
      expect(view_class.warm?).to be(false)
    end

    it "incrementally maintains affected partitions after a write" do
      described_class.new(view_class).rebuild!
      item = Item.create!(category: "books", amount: 100)
      view_class.record_write_change!(write_change(item, :create))

      described_class.new(view_class).refresh!
      expect(view_class.find_by(category: "books").total_amount).to eq(115)
    end

    context "with a GROUP BY view" do
      let(:view_class) { define_view("mv_default_incremental", :sales_by_category_with_totals) }

      before { seed_items(["books", 10], ["games", 20]) }

      it "maintains only the affected partition in place" do
        described_class.new(view_class).rebuild!
        games_id = view_class.unscoped.find_by(category: "games").id

        item = Item.create!(category: "books", amount: 5)
        view_class.record_write_change!(write_change(item, :create))
        described_class.new(view_class).refresh!

        # The unaffected partition's row is preserved (no full rebuild).
        expect(view_class.unscoped.find_by(category: "games").id).to eq(games_id)
        expect(view_class.find_by(category: "books").total_amount).to eq(15)
        expect(view_class.find_by(category: "games").total_amount).to eq(20)
      end
    end
  end
end
