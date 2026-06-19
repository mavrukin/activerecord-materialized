# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::QueryExpressions do
  let(:items) { Item.arel_table }

  it "builds an aliased SUM aggregate" do
    sql = Item.select(described_class.sum_as(items[:amount], as: :total)).to_sql
    expect(sql).to include('SUM("items"."amount") AS total')
  end

  it "builds an aliased COUNT(DISTINCT) aggregate" do
    sql = Item.select(described_class.count_distinct_as(items[:category], as: :categories)).to_sql
    expect(sql).to include('COUNT(DISTINCT "items"."category") AS categories')
  end

  it "builds an aliased COUNT(*) aggregate" do
    sql = Item.select(described_class.count_all_as(as: :n)).to_sql
    expect(sql).to include("COUNT(*) AS n")
  end

  it "builds an aliased SUM(LENGTH(...)) aggregate" do
    sql = Item.select(described_class.sum_length_as(items[:category], as: :chars)).to_sql
    expect(sql).to include('SUM(LENGTH("items"."category")) AS chars')
  end

  it "builds aliased AVG/MIN/MAX aggregates" do
    avg = Item.select(described_class.avg_as(items[:amount], as: :a)).to_sql
    min = Item.select(described_class.min_as(items[:amount], as: :lo)).to_sql
    max = Item.select(described_class.max_as(items[:amount], as: :hi)).to_sql

    expect(avg).to include('AVG("items"."amount") AS a')
    expect(min).to include('MIN("items"."amount") AS lo')
    expect(max).to include('MAX("items"."amount") AS hi')
  end
end
