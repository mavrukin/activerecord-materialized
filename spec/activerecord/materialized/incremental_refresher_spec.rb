# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::IncrementalRefresher do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_incremental_sales_summary"

      materialized_from <<~SQL.squish
        SELECT category, SUM(amount) AS total_amount, COUNT(*) AS row_count
        FROM items
        GROUP BY category
      SQL

      refresh_mode :incremental
      incremental_keys :category
      incremental_from <<~SQL.squish
        SELECT category, SUM(amount) AS total_amount, COUNT(*) AS row_count
        FROM items
        WHERE category = 'books'
        GROUP BY category
      SQL
    end
  end

  before do
    ActiveRecord::Base.connection.execute("DELETE FROM items")
    ActiveRecord::Base.connection.execute(
      "INSERT INTO items (category, amount) VALUES ('books', 10), ('books', 5), ('games', 20)"
    )
    ActiveRecord::Materialized::Refresher.new(view_class).refresh!
  end

  describe "#refresh!" do
    it "merges delta rows into the cache table by key" do
      ActiveRecord::Base.connection.execute("INSERT INTO items (category, amount) VALUES ('books', 100)")

      result = described_class.new(view_class).refresh!(
        ActiveRecord::Base.connection,
        view_class.table_name
      )

      expect(result).to eq(2)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq(
        [["books", 115], ["games", 20]]
      )
    end

    it "leaves unchanged keys intact when the delta is empty" do
      baseline = view_class.order(:category).pluck(:category, :total_amount)

      result = described_class.new(view_class).refresh!(
        ActiveRecord::Base.connection,
        view_class.table_name
      )

      expect(result).to eq(2)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq(baseline)
    end
  end
end
