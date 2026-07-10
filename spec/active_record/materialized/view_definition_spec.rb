# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::ViewDefinition do
  subject(:definition) { described_class.new(source) }

  let(:source) { ViewSources.sales_by_category.having(Item.arel_table[:amount].sum.gt(5)) }

  it "detects incrementally maintainable aggregate views from ActiveRecord relations" do
    expect(definition.incrementally_maintainable?).to be(true)
    expect(definition.group_key_columns).to eq(["category"])
  end

  it "builds scoped maintenance relations for affected partitions" do
    seed_items(["books", 10], ["games", 20])

    scoped = definition.partition_scope([["books"]])
    expect(scoped.map { |row| row.attributes["category"] }).to eq(["books"])
  end

  it "matches a NULL partition key with IS NULL, not IN (NULL)" do
    # a lone NULL key, and a NULL OR'd alongside a present key
    expect(definition.partition_scope([[nil]]).to_sql).to include("IS NULL")
    mixed = definition.partition_scope([["books"], [nil]]).to_sql
    expect(mixed).to include("IS NULL")
    expect { definition.partition_scope([[nil]]).to_a }.not_to raise_error
  end

  it "qualifies a dotted GROUP BY key to its own table" do
    dotted = described_class.new(ViewSources.item_count_by_dotted_category)

    # "items.category" resolves to the qualified column, not a literal dotted name.
    expect(dotted.partition_scope([["books"]]).to_sql).to include('"items"."category"')
  end
end
