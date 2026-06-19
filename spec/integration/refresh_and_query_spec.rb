# frozen_string_literal: true

require "spec_helper"

RSpec.describe "materialized view integration" do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_revenue_by_category"

      materialized_from <<~SQL
        SELECT category,
               SUM(amount) AS revenue,
               AVG(amount) AS average_amount
        FROM items
        GROUP BY category
        HAVING SUM(amount) > 5
      SQL

      depends_on :items
      max_staleness 6.hours

      after_refresh { @last_refresh_note = "completed" }

      def self.last_refresh_note
        @last_refresh_note
      end
    end
  end

  it "supports complex aggregation workflows end-to-end" do
    ActiveRecord::Base.connection.execute("DELETE FROM items")
    rows = [
      ["books", 10], ["books", 20], ["games", 3], ["games", 4], ["tools", 50]
    ]
    rows.each { |category, amount| ActiveRecord::Base.connection.execute("INSERT INTO items (category, amount) VALUES ('#{category}', #{amount})") }

    result = view_class.refresh!
    expect(result.row_count).to eq(3)
    expect(view_class.order(:category).pluck(:category, :revenue)).to eq([
      ["books", 30],
      ["games", 7],
      ["tools", 50]
    ])
    expect(view_class.last_refresh_note).to eq("completed")

    # Simulate read-heavy access pattern
    100.times { view_class.where("revenue > ?", 25).to_a }
    expect(view_class.stale?).to be(false)
  end
end
