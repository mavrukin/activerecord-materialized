# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::MaintenanceDeltaBuilder do
  subject(:builder) { described_class.new(change, ["category"]) }

  let(:change) do
    ActiveRecord::Materialized::WriteChange.from_record(
      Item.new(category: "books", amount: 5),
      :create
    )
  end

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
end
