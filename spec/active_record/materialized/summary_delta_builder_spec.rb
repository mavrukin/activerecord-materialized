# frozen_string_literal: true

require "spec_helper"

module SummaryDeltaBuilderHelpers
  def delta_for(operation, before:, after:)
    change = ActiveRecord::Materialized::WriteChange.new(
      table_name: "items", operation: operation, before: before, after: after
    )
    described_class.new(change, analysis, ["category"]).build.buckets
  end
end

RSpec.describe ActiveRecord::Materialized::SummaryDeltaBuilder do
  include SummaryDeltaBuilderHelpers

  let(:items) { Item.arel_table }
  let(:qe) { ActiveRecord::Materialized::QueryExpressions }
  let(:relation) do
    Item.group(:category).select(
      items[:category],
      qe.sum_as(items[:amount], as: :total),
      qe.count_all_as(as: :rows)
    )
  end
  let(:analysis) { ActiveRecord::Materialized::AggregateAnalysis.new(relation) }

  it "adds the after-snapshot contribution for an insert" do
    buckets = delta_for(:create, before: {}, after: { "category" => "books", "amount" => 5 })

    expect(buckets).to eq(["books"] => { "total" => 5, "rows" => 1 })
  end

  it "subtracts the before-snapshot contribution for a delete" do
    buckets = delta_for(:destroy, before: { "category" => "books", "amount" => 5 }, after: {})

    expect(buckets).to eq(["books"] => { "total" => -5, "rows" => -1 })
  end

  it "nets the change for an in-place value update (row count unchanged)" do
    buckets = delta_for(:update,
                        before: { "category" => "books", "amount" => 5 },
                        after: { "category" => "books", "amount" => 8 })

    expect(buckets).to eq(["books"] => { "total" => 3 })
  end

  it "moves the contribution between partitions on a group-key change" do
    buckets = delta_for(:update,
                        before: { "category" => "books", "amount" => 5 },
                        after: { "category" => "games", "amount" => 5 })

    expect(buckets).to eq(
      ["books"] => { "total" => -5, "rows" => -1 },
      ["games"] => { "total" => 5, "rows" => 1 }
    )
  end

  it "treats a nil summed value as a zero contribution" do
    buckets = delta_for(:create, before: {}, after: { "category" => "books", "amount" => nil })

    expect(buckets).to eq(["books"] => { "rows" => 1 })
  end
end
