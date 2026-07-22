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

  # The class-level terminal/finder surface on a cold aggregate view (#132). Most of it
  # (count/sum/min/max/average/pluck/pick/exists?/find_by) already reads through via the `all`
  # override; the order-dependent finders and primary-key-based methods used to raise
  # "no such column: id" because a read-through derived table has no id.
  # The top-level before seeds books => 2 rows (item_count 2), games => 1 row (item_count 1).
  describe "terminal and finder methods on a cold aggregate view" do
    it "reads calculations, existence, and lookups through to the source", :aggregate_failures do
      expect(view_class.materialized?).to be(false)
      expect(view_class.count).to eq(2)            # two partitions
      expect(view_class.sum(:item_count)).to eq(3) # 2 + 1
      expect(view_class.minimum(:item_count)).to eq(1)
      expect(view_class.maximum(:item_count)).to eq(2)
      expect(view_class.pluck(:category)).to contain_exactly("books", "games")
      expect(view_class.exists?).to be(true)
      expect(view_class.find_by(category: "books").item_count).to eq(2)
    end

    it "serves order-dependent finders by ordering on the GROUP BY key, not the missing id",
       :aggregate_failures do
      expect(view_class.first.category).to eq("books") # ordered by category asc
      expect(view_class.last.category).to eq("games")
      expect(view_class.second.category).to eq("games")
      expect(view_class.take).to be_present
      expect(view_class.implicit_order_column).to eq(["category", nil]) # skip pk via trailing nil
    end

    it "refuses primary-key-bound methods with actionable guidance while cold", :aggregate_failures do
      noop = ->(_) {}

      expect { view_class.ids }.to raise_error(ActiveRecord::Materialized::NotMaterializedError, /rebuild!/)
      expect { view_class.find_each(&noop) }
        .to raise_error(ActiveRecord::Materialized::NotMaterializedError, /rebuild!/)
      expect { view_class.find_in_batches(&noop) }
        .to raise_error(ActiveRecord::Materialized::NotMaterializedError, /rebuild!/)
      expect { view_class.in_batches(&noop) }
        .to raise_error(ActiveRecord::Materialized::NotMaterializedError, /rebuild!/)
    end

    it "runs every method against the cache once warmed", :aggregate_failures do
      view_class.rebuild!(confirm: true)

      expect(view_class.first.category).to eq("books")
      expect(view_class.ids).to match_array(view_class.unscoped.pluck(:id))

      iterated = []
      view_class.find_each { |row| iterated << row.category }
      expect(iterated).to contain_exactly("books", "games")
    end
  end
end
