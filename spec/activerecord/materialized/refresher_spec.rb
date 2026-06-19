# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Refresher do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_sales_summary"

      materialized_from <<~SQL
        SELECT category, SUM(amount) AS total_amount, COUNT(*) AS row_count
        FROM items
        GROUP BY category
      SQL
    end
  end

  before do
    ActiveRecord::Base.connection.execute("DELETE FROM items")
    ActiveRecord::Base.connection.execute("INSERT INTO items (category, amount) VALUES ('books', 10), ('books', 5), ('games', 20)")
  end

  describe "#refresh!" do
    it "materializes query results into the cache table" do
      result = described_class.new(view_class).refresh!

      expect(result.row_count).to eq(2)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq([
        ["books", 15],
        ["games", 20]
      ])
    end

    it "records metadata after refresh" do
      travel_to Time.zone.local(2026, 1, 15, 12, 0, 0) do
        described_class.new(view_class).refresh!
        expect(view_class.last_refreshed_at).to eq(Time.zone.local(2026, 1, 15, 12, 0, 0))
        expect(view_class.metadata.row_count).to eq(2)
        expect(view_class.metadata.refreshing?).to be(false)
      end
    end

    it "runs refresh callbacks" do
      events = []
      view_class.before_refresh { events << :before }
      view_class.after_refresh { events << :after }

      described_class.new(view_class).refresh!
      expect(events).to eq(%i[before after])
    end

    it "updates results when source data changes" do
      described_class.new(view_class).refresh!
      ActiveRecord::Base.connection.execute("INSERT INTO items (category, amount) VALUES ('books', 100)")

      described_class.new(view_class).refresh!
      books_total = view_class.find_by(category: "books").total_amount
      expect(books_total).to eq(115)
    end
  end
end
