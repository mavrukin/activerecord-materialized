# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::ViewDefinition do
  subject(:definition) { described_class.new(source_sql) }

  let(:source_sql) do
    <<~SQL.squish
      SELECT category, SUM(amount) AS total_amount, COUNT(*) AS row_count
      FROM items
      GROUP BY category
      HAVING SUM(amount) > 5
    SQL
  end

  it "detects incrementally maintainable aggregate views" do
    expect(definition.incrementally_maintainable?).to be(true)
    expect(definition.group_key_columns).to eq(["category"])
  end

  it "builds scoped maintenance SQL for affected partitions" do
    scoped = definition.scoped_source_sql([["books"], ["games"]])

    expect(scoped).to include('WHERE "category" IN (\'books\', \'games\')')
    expect(scoped).to include("GROUP BY category")
    expect(scoped).to include("HAVING SUM(amount) > 5")
  end
end
