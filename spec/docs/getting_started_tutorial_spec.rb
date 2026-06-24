# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "activerecord/materialized/refresh_job"

# Executes the code from docs/getting-started.md end to end so the tutorial's
# examples are guaranteed to work. The model, view, and asserted numbers here
# mirror the tutorial step for step; keep them in sync.
class Sale < ActiveRecord::Base
end

module GettingStartedTutorial
end

RSpec.describe GettingStartedTutorial, :integration do
  # The RegionRevenue view exactly as the tutorial defines it.
  let(:region_revenue) do
    Class.new(ActiveRecord::Materialized::View) do
      extend ActiveRecord::Materialized::QueryExpressions

      self.table_name = "mv_region_revenue"

      materialized_from do
        sales = Sale.arel_table
        Sale.group(:region).select(
          sales[:region],
          sum_as(sales[:amount], as: :revenue),
          count_all_as(as: :sales_count)
        )
      end

      depends_on Sale
      refresh_on_change :async
      max_staleness 6.hours
    end
  end

  before do
    ActiveRecord::Base.connection.create_table :sales, force: true do |t|
      t.string :region, null: false
      t.integer :amount, null: false
    end
    # Run async maintenance only on an explicit flush! so the assertions are
    # deterministic (no background timer race).
    ActiveRecord::Materialized::AsyncRefresher.paused = true

    Sale.delete_all
    Sale.create!(region: "west", amount: 100)
    Sale.create!(region: "west", amount: 200)
    Sale.create!(region: "east", amount: 50)
  end

  after { ActiveRecord::Materialized::AsyncRefresher.paused = false }

  it "serves a correct read-through result before the view is built" do
    expect(region_revenue.materialized?).to be(false)
    expect(region_revenue.where(region: "west").pick(:revenue)).to eq(300)
    expect(region_revenue.materialized?).to be(false) # a read never builds the view
  end

  it "builds the view and serves transparent reads from the cache" do
    region_revenue.rebuild!(confirm: true)

    expect(region_revenue.materialized?).to be(true)
    expect(region_revenue.order(revenue: :desc).pluck(:region, :revenue)).to eq(
      [["west", 300], ["east", 50]]
    )
    expect(region_revenue.where(region: "east").pick(:sales_count)).to eq(1)
  end

  # The headline scenario: a write auto-refreshes the view in the background —
  # the app code never calls refresh!/rebuild!. Demonstrated with the ActiveJob
  # dispatcher so the "background worker" is deterministic; the in-process default
  # behaves the same on a debounced thread.
  context "with the :active_job dispatcher (a background worker)" do
    include ActiveJob::TestHelper

    around do |example|
      previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      config = ActiveRecord::Materialized.configuration
      previous_dispatcher = config.refresh_dispatcher
      config.refresh_dispatcher = :active_job
      example.run
      config.refresh_dispatcher = previous_dispatcher
      ActiveJob::Base.queue_adapter = previous_adapter
    end

    it "refreshes itself in the background after a write — no manual refresh" do
      region_revenue.rebuild!(confirm: true)
      expect(region_revenue.where(region: "west").pick(:revenue)).to eq(300)

      # Just a normal write. The gem enqueues a refresh automatically.
      Sale.create!(region: "west", amount: 400)
      expect(region_revenue.dirty?).to be(true)                              # pending in the background
      expect(region_revenue.where(region: "west").pick(:revenue)).to eq(300) # previous snapshot, still fast

      # The worker runs the auto-enqueued job. Nothing here calls refresh!/rebuild!.
      perform_enqueued_jobs

      expect(region_revenue.dirty?).to be(false)
      expect(region_revenue.where(region: "west").pick(:revenue)).to eq(700) # fresh, on its own
    end
  end

  it "refreshes only when stale via refresh_if_stale!" do
    region_revenue.rebuild!(confirm: true)
    expect(region_revenue.stale?).to be(false)
    expect(region_revenue.refresh_if_stale!).to be_nil # fresh: no-op

    Sale.create!(region: "north", amount: 999)
    expect(region_revenue.stale?).to be(true)

    region_revenue.refresh_if_stale!
    expect(region_revenue.where(region: "north").pick(:revenue)).to eq(999)
  end

  it "warms hot partitions ahead of traffic with warm_up!" do
    warming_view = Class.new(ActiveRecord::Materialized::View) do
      extend ActiveRecord::Materialized::QueryExpressions

      self.table_name = "mv_region_revenue"

      materialized_from do
        sales = Sale.arel_table
        Sale.group(:region).select(sales[:region], sum_as(sales[:amount], as: :revenue))
      end

      depends_on Sale
      warm_up { [where(region: "west"), where(region: "east")] }
    end

    warming_view.warm_up!

    expect(warming_view.where(region: "west").pick(:revenue)).to eq(300)
    expect(warming_view.where(region: "east").pick(:revenue)).to eq(50)
  end
end
