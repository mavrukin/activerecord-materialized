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

    it "forwards source.ts_ms as source_ts, ignoring the top-level ts_ms (a different clock)" do
      # source.ts_ms (the DB commit time) is the watermark; the top-level ts_ms is the connector's
      # processing clock and is intentionally ignored (mixing them would break suppression's monotonicity).
      from_source = described_class.to_change_descriptor(
        envelope("u", before: { "category" => "books" }, after: { "category" => "games" },
                      source: { "table" => "items", "ts_ms" => 100 }, ts_ms: 999)
      )
      # A top-level ts_ms alone is not a fallback — it carries no watermark...
      top_only = described_class.to_change_descriptor(envelope("c", after: { "category" => "books" }, ts_ms: 50))
      # ...nor does a non-integer source.ts_ms, or no ts_ms at all (behavior is exactly as before; #106 opt-in).
      non_integer = described_class.to_change_descriptor(
        envelope("c", after: { "category" => "books" }, source: { "table" => "items", "ts_ms" => "100" })
      )
      none = described_class.to_change_descriptor(envelope("c", after: { "category" => "books" }))

      expect(from_source).to include(source_ts: 100)  # source.ts_ms is the watermark, not the top-level 999
      expect(top_only).not_to have_key(:source_ts)    # the top-level ts_ms is not a fallback
      expect(non_integer).not_to have_key(:source_ts) # a non-integer source.ts_ms is ignored
      expect(none).not_to have_key(:source_ts)        # nothing to forward → unchanged behavior
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

    it "forwards source.ts_ms so a later out-of-order envelope is suppressed and freshness advances" do
      # A watermarked create at ts=100 re-aggregates books and records the partition watermark.
      Item.create!(category: "books", amount: 1) # source now has 2 books (out-of-band)
      ActiveRecord::Materialized.ingest_debezium_change(
        envelope("c", after: { "category" => "books" }, source: { "table" => "items", "ts_ms" => 100 })
      )
      expect(view.find_by(category: "books").item_count).to eq(2) # applied
      expect(view.source_watermark).to eq(100)                    # watermark advanced from ts_ms

      # A stale envelope (ts=50 < 100) for the same partition is suppressed as provably-stale.
      Item.create!(category: "books", amount: 1) # source now has 3 books...
      ActiveRecord::Materialized.ingest_debezium_change(
        envelope("c", after: { "category" => "books" }, source: { "table" => "items", "ts_ms" => 50 })
      )
      expect(view.find_by(category: "books").item_count).to eq(2) # ...but ts=50 is suppressed
    end

    it "is a no-op for a tombstone (nil envelope)" do
      expect { ActiveRecord::Materialized.ingest_debezium_change(nil) }.not_to raise_error
      expect(view.find_by(category: "books").item_count).to eq(1) # unchanged
    end
  end
end
