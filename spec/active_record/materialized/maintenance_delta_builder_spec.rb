# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::MaintenanceDeltaBuilder do
  subject(:builder) { described_class.new(change, ["category"]) }

  let(:change) { write_change(Item.new(category: "books", amount: 5), :create) }

  it "extracts partition keys from ActiveRecord create changes" do
    delta = builder.build

    expect(delta.full_partition?).to be(false)
    expect(delta.key_tuples).to eq([["books"]])
  end

  it "widens scope when group keys are absent from the change" do
    change = ActiveRecord::Materialized::WriteChange.new(
      table_name: "items",
      operation: :update,
      before: { "amount" => 5 },
      after: { "amount" => 10 }
    )
    delta = described_class.new(change, ["category"]).build

    expect(delta.full_partition?).to be(true)
  end

  it "preserves falsey group-key values instead of widening" do
    change = ActiveRecord::Materialized::WriteChange.new(
      table_name: "items",
      operation: :create,
      before: {},
      after: { "active" => false }
    )
    delta = described_class.new(change, ["active"]).build

    expect(delta.full_partition?).to be(false)
    expect(delta.key_tuples).to eq([[false]])
  end

  it "extracts both old and new partitions when a group key changes" do
    change = ActiveRecord::Materialized::WriteChange.new(
      table_name: "items",
      operation: :update,
      before: { "category" => "books" },
      after: { "category" => "games" }
    )
    delta = described_class.new(change, ["category"]).build

    expect(delta.key_tuples).to contain_exactly(["games"], ["books"])
  end

  it "widens an update when only one image carries the group key (partial CDC image, #110)" do
    # A non-FULL CDC image: one side has the group key, the other only a non-key column. The side
    # without it could name a different partition (a move), so scope can't be identified => widen.
    before_only = ActiveRecord::Materialized::WriteChange.new(
      table_name: "items", operation: :update, before: { "id" => 1 }, after: { "category" => "games" }
    )
    after_only = ActiveRecord::Materialized::WriteChange.new(
      table_name: "items", operation: :update, before: { "category" => "books" }, after: { "amount" => 10 }
    )

    expect(described_class.new(before_only, ["category"]).build.full_partition?).to be(true) # PK-only before
    expect(described_class.new(after_only, ["category"]).build.full_partition?).to be(true)  # key-less after
  end

  describe "with a partition-key resolver (issue #61)" do
    it "derives single-column keys from the resolver, taking precedence over the payload" do
      # a scalar, chosen over the payload's own "books" category (resolver is authoritative)
      expect(described_class.new(change, ["category"], resolver: ->(_c) { "US" }).build.key_tuples)
        .to eq([["US"]])
      # an array => multiple partitions (e.g. an update that moves a row between them)
      expect(described_class.new(change, ["country"], resolver: ->(_c) { %w[US UK] }).build.key_tuples)
        .to contain_exactly(["US"], ["UK"])
      # a nil value is the NULL partition — kept, not dropped
      expect(described_class.new(change, ["country"], resolver: ->(_c) { ["US", nil] }).build.key_tuples)
        .to contain_exactly(["US"], [nil])
    end

    it "widens to a full recompute when the resolver yields nothing" do
      expect(described_class.new(change, ["country"], resolver: ->(_c) {}).build.full_partition?).to be(true)
      expect(described_class.new(change, ["country"], resolver: ->(_c) { [] }).build.full_partition?).to be(true)
    end

    it "normalizes composite keys and widens a malformed one instead of crashing" do
      single = described_class.new(change, %w[country year], resolver: ->(_c) { ["US", 2024] }).build
      expect(single.key_tuples).to eq([["US", 2024]]) # a single tuple
      many = described_class.new(change, %w[country year], resolver: ->(_c) { [["US", 2024], ["UK", 2023]] }).build
      expect(many.key_tuples).to contain_exactly(["US", 2024], ["UK", 2023]) # an array of tuples
      scalar = described_class.new(change, %w[country year], resolver: ->(_c) { "US" }).build
      expect(scalar.full_partition?).to be(true) # a bare scalar can't be a composite tuple => widen
    end
  end
end
