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
end
