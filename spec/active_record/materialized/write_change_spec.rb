# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::WriteChange do
  before { Item.delete_all }

  describe ".from_record" do
    it "captures the full after-snapshot for a create" do
      item = Item.create!(category: "books", amount: 5)
      change = described_class.from_record(item, :create)

      expect(change.operation).to eq(:create)
      expect(change.table_name).to eq("items")
      expect(change.after).to include("category" => "books", "amount" => 5)
      expect(change.before).to eq({})
    end

    it "captures full old and new snapshots for an update, including unchanged columns" do
      item = Item.create!(category: "books", amount: 5)
      item.update!(category: "games")
      change = described_class.from_record(item, :update)

      expect(change.operation).to eq(:update)
      expect(change.before).to include("category" => "books", "amount" => 5)
      expect(change.after).to include("category" => "games", "amount" => 5)
    end

    it "captures the full before-snapshot for a destroy" do
      item = Item.create!(category: "books", amount: 5)
      item.destroy!
      change = described_class.from_record(item, :destroy)

      expect(change.operation).to eq(:destroy)
      expect(change.before).to include("category" => "books", "amount" => 5)
      expect(change.after).to eq({})
    end

    it "raises for an unsupported operation" do
      item = Item.create!(category: "books", amount: 5)

      expect { described_class.from_record(item, :touch) }
        .to raise_error(ArgumentError, /unsupported write operation/)
    end
  end
end
