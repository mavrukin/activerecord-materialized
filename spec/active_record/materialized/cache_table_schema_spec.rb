# frozen_string_literal: true

require "spec_helper"

# #82 — cache-column types are inferred from the projection (group-key source
# columns + aggregate function), deterministically and without depending on a
# sample row, so they are correct on an empty source and consistent across DB
# engines (the one-row probe typed everything :string when the source was empty).
RSpec.describe ActiveRecord::Materialized::CacheTableSchema do
  it "infers column types from the projection even when the source is empty" do
    Item.delete_all # empty source: the old one-row probe types every column :string
    relation = ViewSources.sales_by_category # category + SUM(amount) AS total_amount + COUNT(id) AS row_count
    types = described_class.column_definitions(ActiveRecord::Base.connection, relation).to_h { |d| [d.name, d.type] }

    expect(types["category"]).to eq(:string)      # group key -> source column type
    expect(types["total_amount"]).to eq(:integer) # SUM over an integer column
    expect(types["row_count"]).to eq(:integer)    # COUNT
  end
end
