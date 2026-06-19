# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::IncrementalMaintainer do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_incremental_sales_summary"

      materialized_from <<~SQL.squish
        SELECT category, SUM(amount) AS total_amount, COUNT(*) AS row_count
        FROM items
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

  describe "#maintain!" do
    it "recomputes only affected partitions without rebuilding the cache table" do
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:execute).and_call_original

      view_class.record_write_delta!("INSERT INTO items (category, amount) VALUES ('books', 100)")
      ActiveRecord::Base.connection.execute("INSERT INTO items (category, amount) VALUES ('books', 100)")
      described_class.new(view_class).maintain!(connection, view_class.table_name)

      expect(connection).not_to have_received(:execute).with(/CREATE TABLE .*_refresh_/)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq(
        [["books", 115], ["games", 20]]
      )
    end
  end
end
