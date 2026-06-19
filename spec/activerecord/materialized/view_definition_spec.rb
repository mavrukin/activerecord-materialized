# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::ViewDefinition do
  subject(:definition) { described_class.new(source) }

  let(:source) do
    Item.group(:category)
        .select("category, SUM(amount) AS total_amount, COUNT(*) AS row_count")
        .having("SUM(amount) > 5")
  end

  it "detects incrementally maintainable aggregate views from ActiveRecord relations" do
    expect(definition.incrementally_maintainable?).to be(true)
    expect(definition.group_key_columns).to eq(["category"])
  end

  it "builds scoped maintenance SQL for affected partitions" do
    scoped = definition.scoped_source_sql([["books"], ["games"]])

    expect(scoped).to include("category")
    expect(scoped).to include("books")
    expect(scoped).to include("games")
    expect(scoped).to include("GROUP BY")
    expect(scoped).to include("HAVING")
  end
end
