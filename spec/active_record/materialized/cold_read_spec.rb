# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::ColdRead do
  let(:view_class) { define_view("mv_cold_read_items", :item_count_by_category) }

  before do
    ActiveRecord::Materialized::DependencyRegistry.reset!
    seed_items(["books", 1], ["books", 2], ["games", 3])
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
