# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::ChangeKeyExtractor do
  subject(:extractor) { described_class.new(sql, ["category"]) }

  let(:sql) { "INSERT INTO items (category, amount) VALUES ('books', 5)" }

  it "extracts partition keys from inserts" do
    delta = extractor.extract

    expect(delta.full_partition?).to be(false)
    expect(delta.key_tuples).to eq([["books"]])
  end

  it "widens scope for unbounded deletes" do
    delta = described_class.new("DELETE FROM items", ["category"]).extract

    expect(delta.full_partition?).to be(true)
  end
end
