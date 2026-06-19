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
    Item.delete_all
    Item.create!(category: "books", amount: 10)
    Item.create!(category: "games", amount: 20)

    scoped = definition.scoped_source([["books"]])
    expect(scoped.map { |row| row.attributes["category"] }).to eq(["books"])
  end
end
