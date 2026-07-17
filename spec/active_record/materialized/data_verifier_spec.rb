# frozen_string_literal: true

require "spec_helper"

# #62 — detecting DATA drift: the materialized cache contents diverging from what
# the source relation would produce now. Cache rows are mutated out-of-band (via
# the cache model directly) to simulate a write the change source missed.
RSpec.describe ActiveRecord::Materialized::DataVerifier do
  let(:view) { define_view("mv_audit_items", :item_count_by_category) }

  before do
    seed_items(["books", 5], ["games", 3], ["toys", 2]) # one item each => item_count 1 per category
    view.rebuild!(confirm: true)
  end

  it "reports no drift for a consistent view" do
    result = described_class.new(view, mode: :full).verify

    expect(result.drifted?).to be(false)
    expect(result.total_partition_count).to eq(3)
  end

  # #94 — verification reads route to a replica via the verification role when one is configured.
  it "runs verification under the verification connection role" do
    allow(ActiveRecord::Materialized::ConnectionRouting).to receive(:verification).and_call_original

    described_class.new(view, mode: :full).verify

    expect(ActiveRecord::Materialized::ConnectionRouting).to have_received(:verification)
  end

  it "detects a corrupted partition value in full mode" do
    view.unscoped.find_by(category: "books").update!(item_count: 999)

    result = described_class.new(view, mode: :full).verify

    expect(result.mismatched_keys).to contain_exactly(["books"])
    expect(result.drifted?).to be(true)
  end

  it "detects value drift in checksum mode" do
    view.unscoped.find_by(category: "games").update!(item_count: 42)

    result = described_class.new(view, mode: :checksum).verify

    expect(result.mismatched_keys).to contain_exactly(["games"])
  end

  it "detects missing and extra partitions in row_count mode" do
    view.unscoped.find_by(category: "toys").destroy! # source has it, cache lost it
    view.create!(category: "ghost", item_count: 7) # cache only

    result = described_class.new(view, mode: :row_count).verify

    expect(result.missing_keys).to contain_exactly(["toys"])
    expect(result.extra_keys).to contain_exactly(["ghost"])
  end

  it "detects a duplicated cache row for a partition" do
    view.create!(category: "books", item_count: 1) # a second "books" row the source has one of

    result = described_class.new(view, mode: :row_count).verify

    expect(result.mismatched_keys).to contain_exactly(["books"]) # count differs, not collapsed away
  end

  it "verifies a random subset and reports coverage under sampling" do
    result = described_class.new(view, mode: :full, sample: 1).verify

    expect(result.checked_partition_count).to eq(1)
    expect(result.total_partition_count).to eq(3)
    expect(result.drifted?).to be(false) # the sampled partition is consistent
  end

  it "raises through verify_data! when any registered view has drifted" do
    view.unscoped.find_by(category: "books").update!(item_count: 0)

    expect { ActiveRecord::Materialized.verify_data!(mode: :full) }
      .to raise_error(ActiveRecord::Materialized::DataVerifier::DataDriftError, /mv_audit_items/)
  end

  it "detects missing partitions when the sample covers every partition" do
    view.unscoped.find_by(category: "toys").destroy!

    result = described_class.new(view, mode: :full, sample: 1.0).verify # full coverage => exhaustive

    expect(result.missing_keys).to contain_exactly(["toys"])
  end

  it "returns an empty result for a zero sample rather than crashing" do
    result = described_class.new(view, mode: :full, sample: 0).verify

    expect(result.checked_partition_count).to eq(0)
    expect(result.drifted?).to be(false)
  end

  it "does not flag a float aggregate whose value differs only in representation" do
    float_view = define_view("mv_avg_amounts", :avg_amount_by_category)
    float_view.rebuild!(confirm: true) # cache stores e.g. 5, source AVG recomputes 5.0

    expect(described_class.new(float_view, mode: :full).verify.drifted?).to be(false)
  end

  it "maps a dotted GROUP BY key to its projected column, in full and sampled modes" do
    dotted_view = define_view("mv_dotted_items", :item_count_by_dotted_category)
    dotted_view.rebuild!(confirm: true)
    # Corrupt every partition so whichever the sample draws is caught (deterministic).
    %w[books games toys].each { |category| dotted_view.unscoped.find_by(category: category).update!(item_count: 999) }

    expect(described_class.new(dotted_view, mode: :full).verify.mismatched_keys)
      .to contain_exactly(["books"], ["games"], ["toys"])
    # The sampled path scopes through partition_scope, which must handle the dotted key.
    sampled = described_class.new(dotted_view, mode: :full, sample: 1).verify
    expect(sampled.checked_partition_count).to eq(1)
    expect(sampled.mismatched_keys.size).to eq(1)
  end

  it "skips a non-grouped view rather than collapsing it to a single row" do
    total_view = define_view("mv_total_items", :total_item_count)
    total_view.rebuild!(confirm: true)

    result = described_class.new(total_view, mode: :full).verify

    expect(result.drifted?).to be(false)
    expect(result.total_partition_count).to eq(0) # nothing partition-based to verify
  end
end
