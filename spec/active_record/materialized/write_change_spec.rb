# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::WriteChange do
  before { Item.delete_all }

  describe ".from_record" do
    it "captures all attributes for a create" do
      item = Item.create!(category: "books", amount: 5)
      change = described_class.from_record(item, :create)

      expect(change.operation).to eq(:create)
      expect(change.table_name).to eq("items")
      expect(change.attributes).to include("category" => "books", "amount" => 5)
      expect(change.previous_attributes).to eq({})
    end

    it "captures old and new values for an update" do
      item = Item.create!(category: "books", amount: 5)
      item.update!(category: "games")
      change = described_class.from_record(item, :update)

      expect(change.operation).to eq(:update)
      expect(change.attributes).to eq("category" => "games")
      expect(change.previous_attributes).to eq("category" => "books")
    end

    it "captures the database state for a destroy" do
      item = Item.create!(category: "books", amount: 5)
      item.destroy!
      change = described_class.from_record(item, :destroy)

      expect(change.operation).to eq(:destroy)
      expect(change.attributes).to include("category" => "books", "amount" => 5)
      expect(change.previous_attributes).to eq({})
    end

    it "raises for an unsupported operation" do
      item = Item.create!(category: "books", amount: 5)

      expect { described_class.from_record(item, :touch) }
        .to raise_error(ArgumentError, /unsupported write operation/)
    end
  end
end
