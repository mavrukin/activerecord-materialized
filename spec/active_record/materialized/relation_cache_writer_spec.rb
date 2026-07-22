# frozen_string_literal: true

require "spec_helper"

# #81 — the full-refresh swap must keep the view table continuously present. On
# engines with transactional DDL (SQLite here, Postgres) the two renames run inside
# a transaction; on MySQL (DDL auto-commits, so a transaction can't make them
# atomic) a single multi-table RENAME TABLE is used — that branch is exercised by
# the real-DB matrix (spec/integration), which SQLite can't run. This guards the
# transactional path across the refactor.
RSpec.describe ActiveRecord::Materialized::RelationCacheWriter do
  it "swaps to the freshly built table, leaving the view present and queryable" do
    view = define_view("mv_swap", :item_count_by_category) { depends_on :items }
    seed_items(["books", 1], ["games", 2])
    view.rebuild!(confirm: true)

    described_class.new(view).atomic_swap!(ViewSources.item_count_by_category)

    expect(view.table_exists?).to be(true)
    expect(view.unscoped.count).to eq(2) # both partitions intact after the swap
  end

  # #128 — the freshly built swap table carries only the schema-default index, so a full rebuild would
  # otherwise drop any other index with the displaced old table (unlike PostgreSQL's REFRESH). The swap
  # captures the live table's indexes and re-creates the missing ones on the table that replaces it.
  describe "index preservation across the swap" do
    def index_signatures(table)
      ActiveRecord::Base.connection.indexes(table).map { |index| [index.columns, index.unique] }
    end

    it "keeps a user-added index across rebuild! without duplicating the default one" do
      view = define_view("mv_swap_idx", :item_count_by_category) { depends_on :items }
      seed_items(["books", 1], ["games", 2])
      view.rebuild!(confirm: true)
      ActiveRecord::Base.connection.add_index("mv_swap_idx", :item_count, name: "idx_user_item_count")

      described_class.new(view).atomic_swap!(ViewSources.item_count_by_category)

      # both the default unique partition-key index and the user index survive; neither is duplicated
      expect(index_signatures("mv_swap_idx")).to contain_exactly([["category"], true], [["item_count"], false])
    end

    it "restores an index on a table that predates the schema-default index" do
      view = define_view("mv_swap_legacy", :item_count_by_category) { depends_on :items }
      seed_items(["books", 1], ["games", 2])
      # Simulate a cache table built before the default index existed: no index on the live table.
      ActiveRecord::Base.connection.create_table("mv_swap_legacy", force: true) do |t|
        t.string :category
        t.integer :item_count
      end
      ActiveRecord::Base.connection.add_index("mv_swap_legacy", :category, unique: true, name: "legacy_cat")
      view.metadata.mark_warm!

      described_class.new(view).atomic_swap!(ViewSources.item_count_by_category)

      expect(index_signatures("mv_swap_legacy")).to include([["category"], true])
    end
  end
end
