# frozen_string_literal: true

require "spec_helper"

module DeltaMaintainerHelpers
  # Build the WriteChange a record produced and apply its delta to the cache.
  def apply_change(record, operation)
    change = ActiveRecord::Materialized::WriteChange.from_record(record, operation)
    delta = ActiveRecord::Materialized::SummaryDeltaBuilder.new(change, analysis, group_columns).build
    maintainer.apply!(delta)
  end

  def materialized_view
    view_class.unscoped.order(:category).pluck(:category, :total_amount, :row_count)
  end

  def raw_query
    ViewSources.sales_by_category.order(:category).map { |row| [row.category, row.total_amount, row.row_count] }
  end

  def perform_random_write(categories)
    case %i[create create update destroy].sample
    when :create
      apply_change(Item.create!(category: categories.sample, amount: rand(0..30)), :create)
    when :update
      mutate_random(categories) { |item| item.update!(category: categories.sample, amount: rand(0..30)) }
    when :destroy
      mutate_random(categories, &:destroy!)
    end
  end

  def mutate_random(_categories)
    item = Item.order("RANDOM()").first
    return if item.nil?

    yield item
    apply_change(item, item.destroyed? ? :destroy : :update)
  end
end

RSpec.describe ActiveRecord::Materialized::DeltaMaintainer do
  include DeltaMaintainerHelpers

  subject(:maintainer) { described_class.new(view_class) }

  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_delta_sales"
      materialized_from { ViewSources.sales_by_category }
    end
  end
  let(:analysis) { ActiveRecord::Materialized::AggregateAnalysis.new(view_class.resolved_source) }
  let(:group_columns) { view_class.maintenance_key_columns }

  before do
    Item.delete_all
    Item.create!(category: "books", amount: 10)
    Item.create!(category: "books", amount: 5)
    Item.create!(category: "games", amount: 20)
    view_class.rebuild!(confirm: true)
  end

  it "inserts a brand-new partition" do
    apply_change(Item.create!(category: "tools", amount: 7), :create)

    expect(materialized_view).to eq(raw_query)
    expect(view_class.unscoped.find_by(category: "tools").total_amount).to eq(7)
  end

  it "increments an existing partition" do
    apply_change(Item.create!(category: "books", amount: 100), :create)

    expect(view_class.unscoped.find_by(category: "books").total_amount).to eq(115)
    expect(materialized_view).to eq(raw_query)
  end

  it "deletes a partition once its last row is gone" do
    only_game = Item.find_by(category: "games")
    only_game.destroy!
    apply_change(only_game, :destroy)

    expect(view_class.unscoped.find_by(category: "games")).to be_nil
    expect(materialized_view).to eq(raw_query)
  end

  it "moves a row between partitions on a group-key change" do
    item = Item.find_by(category: "games")
    item.update!(category: "books")
    apply_change(item, :update)

    expect(materialized_view).to eq(raw_query)
  end

  it "stays equal to the raw query under a random write sequence" do
    categories = %w[books games tools widgets]

    120.times do |i|
      perform_random_write(categories)
      expect(materialized_view).to eq(raw_query) if (i % 12).zero?
    end

    expect(materialized_view).to eq(raw_query)
  end

  describe "live maintenance flow" do
    it "routes a warm delta-maintainable view's writes through summary-delta IVM" do
      store = ActiveRecord::Materialized::MaintenanceStore.new(view_class)
      expect(view_class.delta_maintaining?).to be(true)

      item = Item.create!(category: "books", amount: 50)
      view_class.record_write_change!(ActiveRecord::Materialized::WriteChange.from_record(item, :create))

      expect(store.pending).to be_a(ActiveRecord::Materialized::SummaryDelta)

      view_class.refresh!

      expect(view_class.unscoped.find_by(category: "books").total_amount).to eq(65)
      expect(materialized_view).to eq(raw_query)
      expect(store.pending).to be_nil
    end
  end
end
