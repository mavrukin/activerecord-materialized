# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Metadata do
  let(:view_class) { define_view("mv_metadata_test", :item_id_sample) }
  let(:metadata) { described_class.new(view_class) }

  it "marks failed refreshes" do
    metadata.mark_refreshing!
    metadata.mark_failed!(StandardError.new("boom"))

    expect(metadata.refreshing?).to be(false)
    expect(metadata.record.last_error).to eq("boom")
  end

  it "records refreshed timestamps when Time.zone is unset" do
    allow(Time).to receive(:zone).and_return(nil)

    metadata.mark_refreshed!(row_count: 2, duration_ms: 15)

    expect(metadata.last_refreshed_at).to be_within(1.second).of(Time.now.utc)
    expect(metadata.dirty?).to be(false)
  end

  it "provisions the schema once, not on every access" do
    allow(ActiveRecord::Materialized::Metadata::Schema).to receive(:ensure_table!).and_call_original

    metadata.mark_dirty!
    10.times { metadata.dirty? }
    metadata.mark_refreshing!
    metadata.record

    expect(ActiveRecord::Materialized::Metadata::Schema).to have_received(:ensure_table!).once
  end

  # #94 — a replica read trails the primary, so the replica-lag budget tightens max_staleness.
  describe "#stale? with a replica-lag budget" do
    let(:view_class) { define_view("mv_replica_lag", :item_id_sample) { max_staleness 1.hour } }

    after { ActiveRecord::Materialized.configuration.replica_lag = 0 }

    it "goes stale sooner by the configured replica-lag budget" do
      metadata.record.update!(last_refreshed_at: 40.minutes.ago, dirty: false)

      expect(metadata.stale?).to be(false) # 40 min old, inside the 1-hour window => fresh by default

      ActiveRecord::Materialized.configuration.replica_lag = 30.minutes # effective window => 30 min
      expect(metadata.stale?).to be(true) # 40 min old now exceeds it
    end
  end
end
