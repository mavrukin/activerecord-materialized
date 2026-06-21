# frozen_string_literal: true

require "spec_helper"

RSpec.describe "cold-read behavior" do # rubocop:disable RSpec/DescribeClass
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_cold_read_items"
      materialized_from { ViewSources.item_count_by_category }
    end
  end

  before do
    ActiveRecord::Materialized::DependencyRegistry.reset!
    Item.delete_all
    Item.create!(category: "books", amount: 1)
    Item.create!(category: "books", amount: 2)
    Item.create!(category: "games", amount: 3)
  end

  describe "rebuild!" do
    it "refuses to run without confirmation and leaves the view cold" do
      expect { view_class.rebuild! }.to raise_error(ArgumentError, /confirm: true/)
      expect(view_class.materialized?).to be(false)
    end

    it "materializes and marks the view warm with confirm: true" do
      view_class.rebuild!(confirm: true)

      expect(view_class.materialized?).to be(true)
      expect(view_class.where(category: "books").pick(:item_count)).to eq(2)
    end
  end

  describe "default :read_through" do
    it "serves correct results from the source while cold" do
      expect(view_class.materialized?).to be(false)
      expect(view_class.where(category: "books").pick(:item_count)).to eq(2)
      expect(view_class.count).to eq(2)
    end

    it "reflects live writes immediately while cold" do
      expect(view_class.where(category: "games").pick(:item_count)).to eq(1)
      Item.create!(category: "games", amount: 9)
      expect(view_class.where(category: "games").pick(:item_count)).to eq(2)
    end

    it "never materializes the view from a read" do
      view_class.where(category: "books").to_a
      view_class.count

      expect(view_class.materialized?).to be(false)
    end
  end

  describe ":raise" do
    it "raises NotMaterializedError on a cold read" do
      view_class.cold_read :raise

      expect { view_class.count }.to raise_error(ActiveRecord::Materialized::NotMaterializedError, /rebuild!/)
    end

    it "serves from the cache once materialized" do
      view_class.cold_read :raise
      view_class.rebuild!(confirm: true)

      expect(view_class.count).to eq(2)
    end
  end

  describe ":serve_stale" do
    it "serves the empty cache while cold" do
      view_class.cold_read :serve_stale

      expect(view_class.count).to eq(0)
    end
  end
end
