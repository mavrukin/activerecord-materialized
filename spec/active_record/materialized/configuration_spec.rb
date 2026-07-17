# frozen_string_literal: true

require "spec_helper"
require "active_job" # so the unset dispatcher default resolves via real ActiveJob presence below

RSpec.describe ActiveRecord::Materialized::Configuration do
  let(:config) { described_class.new }

  it "provides sensible defaults" do
    expect(config.metadata_table_name).to eq("ar_materialized_view_metadata")
    expect(config.default_refresh_strategy).to eq(:async)
    expect(config.atomic_swap_refresh).to be(true)
    expect(config.refresh_queue_name).to eq(:materialized_views)
    expect(config.reconcile_queue_name).to eq(:materialized_views) # falls back to the refresh queue
  end

  it "defaults to no writer/replica routing or replica-lag budget (#94)" do
    expect(config.maintenance_role).to be_nil # no routing unless the app configures the roles
    expect(config.verification_role).to be_nil
    expect(config.replica_lag).to eq(0)
  end

  it "yields the global configuration to the configure block" do
    yielded = nil
    ActiveRecord::Materialized.configure { |yielded_config| yielded = yielded_config }

    expect(yielded).to be(ActiveRecord::Materialized.configuration)
  end

  describe "#refresh_dispatcher" do
    it "defaults to :active_job when ActiveJob is loaded (exercises the real resolution, un-stubbed)" do
      # ActiveJob is required above, so this hits the real active_job_available?, not a stub —
      # guarding against a regression that silently reverts the default to in-process :async.
      expect(config.refresh_dispatcher).to eq(:active_job)
    end

    it "falls back to :async without ActiveJob, and an explicit value always wins" do
      allow(config).to receive(:active_job_available?).and_return(false)
      expect(config.refresh_dispatcher).to eq(:async) # no ActiveJob => in-process refresher

      config.refresh_dispatcher = :async
      allow(config).to receive(:active_job_available?).and_return(true)
      expect(config.refresh_dispatcher).to eq(:async) # explicit assignment wins over availability
    end
  end

  describe "#reconcile_queue_name" do
    it "inherits the refresh queue by default but can be set independently" do
      config.refresh_queue_name = :mv_refresh
      expect(config.reconcile_queue_name).to eq(:mv_refresh) # inherits when unset

      config.reconcile_queue_name = :mv_reconcile
      expect(config.reconcile_queue_name).to eq(:mv_reconcile) # explicit override wins
    end
  end
end
