# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::DebeziumEnvelope do
  # A Debezium change envelope (string keys, as a decoder emits) for the items table.
  def envelope(operation, **images)
    { "op" => operation, "source" => { "table" => "items" } }.merge(images.transform_keys(&:to_s))
  end

  describe ".to_change_descriptor" do
    it "maps each op to the gem operation, carrying the before/after images" do
      create = described_class.to_change_descriptor(envelope("c", after: { "category" => "books" }))
      snapshot = described_class.to_change_descriptor(envelope("r", after: { "category" => "books" }))
      update = described_class.to_change_descriptor(
        envelope("u", before: { "category" => "books" }, after: { "category" => "games" })
      )
      destroy = described_class.to_change_descriptor(envelope("d", before: { "category" => "games" }))

      expect(create).to include(operation: :create, before: nil, after: { "category" => "books" })
      expect(snapshot).to include(operation: :create) # a snapshot read is a create
      expect(update).to include(operation: :update, before: { "category" => "books" }, after: { "category" => "games" })
      expect(destroy).to include(operation: :destroy, before: { "category" => "games" }, after: nil)
    end

    it "resolves the table from source.table, honoring a non-blank override and ignoring a blank one" do
      event = envelope("c", after: { "category" => "books" })

      expect(described_class.to_change_descriptor(event)).to include(table: "items") # from source.table
      expect(described_class.to_change_descriptor(event, :other)).to include(table: "other") # explicit override
      expect(described_class.to_change_descriptor(event, "")).to include(table: "items") # blank override → falls back
    end

    it "accepts symbol keys as well as string keys" do
      descriptor = described_class.to_change_descriptor(op: "u", before: { category: "a" },
                                                        after: { category: "b" }, source: { table: "items" })

      expect(descriptor).to include(table: "items", operation: :update)
    end

    it "unwraps a nested Debezium payload (an envelope without the ExtractNewRecordState SMT)" do
      nested = { "payload" => { "op" => "u", "before" => { "category" => "books" },
                                "after" => { "category" => "games" }, "source" => { "table" => "items" } } }

      expect(described_class.to_change_descriptor(nested)).to include(operation: :update, table: "items")
    end

    it "returns nil for a tombstone (nil envelope)" do
      expect(described_class.to_change_descriptor(nil)).to be_nil
    end

    it "raises on a mis-shaped envelope, an unsupported op, or an undeterminable table" do
      # A non-Debezium/Maxwell envelope carries no op — raise loudly rather than silently drop it.
      expect { described_class.to_change_descriptor("type" => "insert", "data" => {}) }
        .to raise_error(ArgumentError, /no op/)
      expect { described_class.to_change_descriptor(envelope("t")) }
        .to raise_error(ArgumentError, /unsupported Debezium op/)
      expect { described_class.to_change_descriptor("op" => "c") }
        .to raise_error(ArgumentError, /could not determine the table/)
    end
  end

  describe ".ingest_debezium_change" do
    let(:view) { externally_fed_view("mv_debezium", immediate: true) }

    before do
      seed_items(["books", 1]) # one book in the source
      view.rebuild!(confirm: true) # cache: books => 1
    end

    it "relays a change envelope through the ingestion API so the view converges" do
      Item.create!(category: "books", amount: 1) # a second book, out-of-band (the :none view isn't notified)
      ActiveRecord::Materialized.ingest_debezium_change(envelope("c", after: { "category" => "books" }))

      expect(view.find_by(category: "books").item_count).to eq(2) # the relayed create re-aggregated books
    end

    it "is a no-op for a tombstone (nil envelope)" do
      expect { ActiveRecord::Materialized.ingest_debezium_change(nil) }.not_to raise_error
      expect(view.find_by(category: "books").item_count).to eq(1) # unchanged
    end
  end
end
