# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::DependencyRegistry do
  let(:view_class) do
    define_view("mv_dependency_registry", :item_count_by_category) { depends_on :items }
  end

  before do
    described_class.reset!
    Item.delete_all
    view_class # defining the class registers its :items dependency
  end

  it "maps a symbol dependency to its table name" do
    expect(described_class.views_for_table("items")).to include(view_class)
  end

  it "returns an empty list for tables with no dependents" do
    expect(described_class.views_for_table("widgets")).to eq([])
  end

  it "registers dependencies declared as model classes" do
    model_dependent = define_view("mv_model_dependency", :item_count_by_category) { depends_on Item }

    expect(described_class.views_for_table("items")).to include(model_dependent)
  end

  it "marks dependent views dirty when their source table changes" do
    view_class.rebuild!(confirm: true)
    expect(view_class.dirty?).to be(false)

    described_class.mark_dirty_for_tables!(["items"])
    expect(view_class.dirty?).to be(true)
  end

  it "drops a cold view's un-appliable full recompute at the merge! chokepoint (#120)" do
    # mark_dirty enqueues a full recompute a cold view can't apply. Rather than store a full_partition
    # (which would absorb every later populate-on-read delta and permanently kill repopulation), the
    # merge! chokepoint drops it and resets the fresh set, so reads simply fall through to the source.
    cold = define_view("mv_cold_mark_dirty", :item_count_by_category) { depends_on :items }
    seed_items(["books", 1])
    cold.where(category: "books").to_a # cold read-miss enqueues maintenance...
    cold.refresh!                      # ...which populates 'books' and marks it fresh
    expect(ActiveRecord::Materialized::PartitionState.new(cold).all_fresh?([["books"]])).to be(true)

    described_class.mark_dirty_for_tables!(["items"])

    expect(ActiveRecord::Materialized::MaintenanceStore.new(cold).pending).to be_nil # dropped, not stuck
    # The fresh set is reset, so the previously-fresh 'books' partition now reads through to source.
    expect(ActiveRecord::Materialized::PartitionState.new(cold).all_fresh?([["books"]])).to be(false)
  end

  it "ignores writes to materialized-view and metadata tables" do
    metadata_table = ActiveRecord::Materialized.metadata_table_name

    expect { described_class.mark_dirty_for_tables!(["mv_dependency_registry", metadata_table]) }
      .not_to raise_error
  end
end
