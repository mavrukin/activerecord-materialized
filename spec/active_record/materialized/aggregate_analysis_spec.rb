# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::AggregateAnalysis do
  let(:items) { Item.arel_table }
  let(:qe) { ActiveRecord::Materialized::QueryExpressions }

  it "classifies each projected aggregate" do
    relation = Item.group(:category).select(
      items[:category],
      qe.sum_as(items[:amount], as: :total),
      qe.count_all_as(as: :rows),
      qe.avg_as(items[:amount], as: :avg_amount),
      qe.max_as(items[:amount], as: :top),
      qe.count_distinct_as(items[:category], as: :distinct_categories)
    )
    by_name = described_class.new(relation).aggregate_columns.to_h { |column| [column.name, column.function] }

    expect(by_name).to eq(
      "total" => :sum, "rows" => :count_star, "avg_amount" => :avg,
      "top" => :max, "distinct_categories" => :count_distinct
    )
  end

  describe "#delta_maintainable?" do
    it "is true for a single-table GROUP BY of SUM and COUNT(*)" do
      relation = Item.group(:category).select(
        items[:category], qe.sum_as(items[:amount], as: :total), qe.count_all_as(as: :rows)
      )

      expect(described_class.new(relation).delta_maintainable?).to be(true)
    end

    it "treats COUNT of a NOT NULL column as a trustworthy row count" do
      relation = Item.group(:category).select(items[:category], qe.count_as(items[:id], as: :rows))
      analysis = described_class.new(relation)

      expect(analysis.delta_maintainable?).to be(true)
      expect(analysis.row_count_column&.name).to eq("rows")
    end

    it "is false without a trustworthy row count (SUM only)" do
      relation = Item.group(:category).select(items[:category], qe.sum_as(items[:amount], as: :total))

      expect(described_class.new(relation).delta_maintainable?).to be(false)
    end

    it "is false for AVG / MIN / MAX / COUNT(DISTINCT)" do
      relation = Item.group(:category).select(
        items[:category], qe.count_all_as(as: :rows), qe.avg_as(items[:amount], as: :avg_amount)
      )

      expect(described_class.new(relation).delta_maintainable?).to be(false)
    end

    it "is false with a HAVING clause" do
      relation = Item.group(:category)
                     .select(items[:category], qe.count_all_as(as: :rows))
                     .having(items[:amount].sum.gt(5))

      expect(described_class.new(relation).delta_maintainable?).to be(false)
    end

    it "is false for a non-grouped aggregate" do
      relation = Item.select(qe.count_all_as(as: :rows))

      expect(described_class.new(relation).delta_maintainable?).to be(false)
    end
  end
end
