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
end
