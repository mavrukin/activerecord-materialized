# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::IncrementalMaintainer do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_incremental_sales_summary"

      materialized_from { ViewSources.sales_by_category }
    end
  end

  before do
    Item.delete_all
    Item.create!(category: "books", amount: 10)
    Item.create!(category: "books", amount: 5)
    Item.create!(category: "games", amount: 20)
    ActiveRecord::Materialized::Refresher.new(view_class).refresh!
  end

  describe "#maintain!" do
    it "recomputes only affected partitions without rebuilding the cache table" do
      connection = ActiveRecord::Base.connection
      allow(connection).to receive(:execute).and_call_original

      item = Item.create!(category: "books", amount: 100)
      view_class.record_write_change!(ActiveRecord::Materialized::WriteChange.from_record(item, :create))
      described_class.new(view_class).maintain!(connection, view_class.table_name)

      expect(connection).not_to have_received(:execute)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq(
        [["books", 115], ["games", 20]]
      )
    end
  end
end
