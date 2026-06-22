# frozen_string_literal: true

require "spec_helper"

module MaterializedViewIntegration
end

RSpec.describe MaterializedViewIntegration, :integration do
  let(:view_class) do
    define_view("mv_revenue_by_category", :revenue_by_category) do
      depends_on :items
      max_staleness 6.hours

      after_refresh { @last_refresh_note = "completed" }

      class << self
        attr_reader :last_refresh_note
      end
    end
  end

  it "supports complex aggregation workflows end-to-end" do
    seed_items(["books", 10], ["books", 20], ["games", 3], ["games", 4], ["tools", 50])

    result = view_class.rebuild!(confirm: true)
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
