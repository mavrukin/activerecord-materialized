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

  describe "DISTINCT projection without GROUP BY (the distinct lookup)" do
    it "treats a distinct key projection as incrementally maintainable" do
      # SELECT DISTINCT category ≡ GROUP BY category (no aggregates), so its projected
      # column is the partition key and it takes the scoped-recompute path.
      symbol_form = described_class.new(ViewSources.distinct_categories)
      arel_form = described_class.new(ViewSources.distinct_categories_arel)

      expect(symbol_form.incrementally_maintainable?).to be(true)
      expect(symbol_form.group_key_columns).to eq(["category"])
      expect(arel_form.incrementally_maintainable?).to be(true)
      expect(arel_form.group_key_columns).to eq(["category"])
    end

    it "builds scoped maintenance relations for a distinct key projection" do
      seed_items(["books", 10], ["books", 20], ["games", 5])

      scoped = described_class.new(ViewSources.distinct_categories).partition_scope([["books"]])
      expect(scoped.map { |row| row.attributes["category"] }).to eq(["books"])
    end

    it "does not treat a distinct projection that includes an aggregate as key-partitioned" do
      # DISTINCT + COUNT(*) is not a pure distinct lookup; the projection is not all
      # plain key columns, so it must fall back to full refresh (no partition keys).
      definition = described_class.new(ViewSources.distinct_with_aggregate)

      expect(definition.incrementally_maintainable?).to be(false)
      expect(definition.group_key_columns).to eq([])
    end

    it "does not treat a non-distinct plain projection as key-partitioned" do
      # A plain SELECT without DISTINCT and without GROUP BY has no partition identity.
      definition = described_class.new(Item.select(:category))

      expect(definition.incrementally_maintainable?).to be(false)
    end
  end
end
