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
      attributes: { "amount" => 10 },
      previous_attributes: { "amount" => 5 }
    )
    delta = described_class.new(change, ["category"]).build

    expect(delta.full_partition?).to be(true)
  end
end
