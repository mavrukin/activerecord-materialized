# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::PartitionKeyedStore do
  let(:view_class) { define_view("mv_keyed_store", :item_count_by_category) }

  # The per-partition stores must serialize a partition key identically, or a fresh mark and a
  # watermark would key the same partition differently and lookups would silently miss. Descending
  # from this shared base — with a single serialize — is what guarantees they can't diverge (#115).
  it "is the shared base both per-partition stores build on, with one partition-key serialization" do
    expect(ActiveRecord::Materialized::PartitionState).to be < described_class
    expect(ActiveRecord::Materialized::SourceWatermark).to be < described_class

    tuple = ["books", 42] # a composite key with a non-string member
    partition_state = ActiveRecord::Materialized::PartitionState.new(view_class)
    source_watermark = ActiveRecord::Materialized::SourceWatermark.new(view_class)

    # Identical serialization across stores (the correctness-critical invariant #115 protects)...
    expect(partition_state.send(:serialize, tuple)).to eq(source_watermark.send(:serialize, tuple))
    # ...and the stable stored form: JSON of the stringified members.
    expect(partition_state.send(:serialize, tuple)).to eq(%w[books 42].to_json)
  end
end
