# frozen_string_literal: true

require "spec_helper"

module RefreshAndQueryIntegrationHelpers
  module_function

  def seed_items!
    Item.delete_all
    [
      ["books", 10], ["books", 20], ["games", 3], ["games", 4], ["tools", 50]
    ].each { |category, amount| Item.create!(category: category, amount: amount) }
  end
end

module MaterializedViewIntegration
end

RSpec.describe MaterializedViewIntegration, :integration do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_revenue_by_category"

      materialized_from { ViewSources.revenue_by_category }

      depends_on :items
      max_staleness 6.hours

      after_refresh { @last_refresh_note = "completed" }

      class << self
        attr_reader :last_refresh_note
      end
    end
  end

  it "supports complex aggregation workflows end-to-end" do
    RefreshAndQueryIntegrationHelpers.seed_items!

    result = view_class.refresh!
    expect(result.row_count).to eq(3)
    expect(view_class.order(:category).pluck(:category, :revenue)).to eq(
      [
        ["books", 30],
        ["games", 7],
        ["tools", 50]
      ]
    )
    expect(view_class.last_refresh_note).to eq("completed")

    revenue = view_class.arel_table[:revenue]
    100.times { view_class.where(revenue.gt(25)).to_a }
    expect(view_class.stale?).to be(false)
  end
end
