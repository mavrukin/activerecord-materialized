# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Configuration do
  it "provides sensible defaults" do
    config = described_class.new

    expect(config.metadata_table_name).to eq("ar_materialized_view_metadata")
    expect(config.default_refresh_strategy).to eq(:async)
    expect(config.refresh_dispatcher).to eq(:async)
    expect(config.atomic_swap_refresh).to be(true)
    expect(config.refresh_queue_name).to eq(:materialized_views)
  end

  it "yields the global configuration to the configure block" do
    yielded = nil
    ActiveRecord::Materialized.configure { |config| yielded = config }

    expect(yielded).to be(ActiveRecord::Materialized.configuration)
  end
end
