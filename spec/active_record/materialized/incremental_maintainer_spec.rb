# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::IncrementalMaintainer do
  let(:view_class) { define_view("mv_incremental_sales_summary", :sales_by_category) }

  before do
    seed_items(["books", 10], ["books", 5], ["games", 20])
    ActiveRecord::Materialized::Refresher.new(view_class).rebuild!
  end

  describe "#maintain!" do
    it "recomputes only the affected partition, leaving others untouched" do
      connection = ActiveRecord::Base.connection
      games_id = view_class.unscoped.find_by(category: "games").id

      Item.create!(category: "books", amount: 100)
      # Drive the recompute path directly with a scoped delta (delta-maintainable
      # views otherwise route through summary-delta IVM).
      ActiveRecord::Materialized::MaintenanceStore.new(view_class).merge!(
        ActiveRecord::Materialized::MaintenanceDelta.scoped([["books"]])
      )
      described_class.new(view_class).maintain!(connection, view_class.table_name)

      # The unaffected partition's row is preserved (not part of a full rebuild).
      expect(view_class.unscoped.find_by(category: "games").id).to eq(games_id)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq(
        [["books", 115], ["games", 20]]
      )
    end
  end
end
