# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::WriteOutbox do
  let(:connection) { ActiveRecord::Base.connection }
  let(:record_class) { ActiveRecord::Materialized::WriteOutboxRecord }

  # A view fed only by the outbox (change_source :none, so callbacks never maintain it): the raw
  # writes below reach it exclusively through the trigger → outbox → drain path.
  def outbox_view(table_name)
    define_view(table_name, :sales_by_category_with_totals) do
      change_source :none
      depends_on :items
      refresh_on_change :immediate
    end
  end

  describe ".install_triggers! capture" do
    it "records raw INSERT/UPDATE/DELETE as scoped before/after key images" do
      described_class.install_triggers!(:items, key_columns: [:category])

      # Writes that bypass ActiveRecord entirely — no callbacks, no ingestion call.
      connection.execute("INSERT INTO items (category, amount) VALUES ('books', 10)")
      connection.execute("UPDATE items SET category = 'games' WHERE category = 'books'")
      connection.execute("DELETE FROM items WHERE category = 'games'")

      rows = record_class.order(:id).to_a
      # A create captures the new-image key only (the new partition)...
      expect(rows[0]).to have_attributes(operation: "create", key_before: nil, key_after: '{"category":"books"}')
      # ...an update captures both (so a partition-moving update maintains old and new)...
      expect(rows[1]).to have_attributes(operation: "update", key_before: '{"category":"books"}',
                                         key_after: '{"category":"games"}')
      # ...a destroy captures the old-image key only (the old partition).
      expect(rows[2]).to have_attributes(operation: "destroy", key_before: '{"category":"games"}', key_after: nil)
    end

    it "captures an empty image for an un-grouped view, widening to a full recompute" do
      # No key columns: every write relays an empty object, which from_descriptor widens to a full
      # recompute — correct for a whole-table (un-grouped) aggregate.
      described_class.install_triggers!(:items, key_columns: [])
      connection.execute("INSERT INTO items (category, amount) VALUES ('books', 10)")

      expect(record_class.sole.key_after).to eq("{}")
    end
  end

  describe ".drain!" do
    it "relays captured writes into scoped maintenance and clears the outbox" do
      view = outbox_view("mv_wob_drain")
      seed_items(["books", 10])
      view.rebuild!(confirm: true) # cache: books => 10
      described_class.install_triggers!(:items, key_columns: [:category])

      connection.execute("INSERT INTO items (category, amount) VALUES ('books', 5)")
      expect(view.find_by(category: "books").total_amount).to eq(10) # invisible until drained

      drained = ActiveRecord::Materialized.drain_write_outbox!

      expect(drained).to eq(1) # returns the count relayed
      expect(view.find_by(category: "books").total_amount).to eq(15) # books partition re-aggregated
      expect(record_class.count).to eq(0) # relayed rows deleted
      expect(ActiveRecord::Materialized.drain_write_outbox!).to eq(0) # a second drain no-ops
    end

    it "bounds a batch with limit, leaving the rest for the next pass" do
      described_class.install_triggers!(:items, key_columns: [:category])
      connection.execute("INSERT INTO items (category, amount) VALUES ('a', 1), ('b', 2), ('c', 3)")

      expect(ActiveRecord::Materialized.drain_write_outbox!(limit: 2)).to eq(2)
      expect(record_class.count).to eq(1) # the third row remains queued
    end

    it "is a safe no-op before any triggers are installed (outbox table absent)" do
      # A scheduled drain must not error if the outbox migration hasn't been applied yet.
      expect(connection.data_source_exists?(described_class.table_name)).to be(false)
      expect(ActiveRecord::Materialized.drain_write_outbox!).to eq(0)
    end

    it "isolates a failing relay so one poison row does not block the batch" do
      described_class.install_triggers!(:items, key_columns: [:category])
      connection.execute("INSERT INTO items (category, amount) VALUES ('poison', 1), ('ok', 2)")
      poison_id = record_class.order(:id).first.id

      # One row's relay raises (its view's scoped recompute fails); the healthy row must still drain.
      allow(ActiveRecord::Materialized).to receive(:ingest_change).and_wrap_original do |original, **kwargs|
        raise ActiveRecord::StatementInvalid, "boom" if kwargs[:after]&.fetch("category", nil) == "poison"

        original.call(**kwargs)
      end

      drained = described_class.drain!

      expect(drained).to eq(1) # the healthy row relayed...
      expect(record_class.pluck(:id)).to eq([poison_id]) # ...the poison row retained for retry
    end
  end

  describe "lifecycle" do
    it "is idempotent to reinstall, and uninstall stops capture" do
      described_class.install_triggers!(:items, key_columns: [:category])
      described_class.install_triggers!(:items, key_columns: [:category]) # re-install drops + recreates

      described_class.uninstall_triggers!(:items)
      connection.execute("INSERT INTO items (category, amount) VALUES ('books', 10)")

      expect(record_class.count).to eq(0) # triggers removed — nothing captured
    end
  end

  describe ".ensure_table!" do
    it "provisions the outbox table once and is idempotent" do
      described_class.ensure_table!
      expect(connection.data_source_exists?(described_class.table_name)).to be(true)
      expect { described_class.ensure_table! }.not_to raise_error # no-op when already present
    end
  end

  describe "unsupported adapter" do
    it "raises rather than emitting wrong SQL" do
      # A non-SQLite/MySQL/Postgres adapter has no trigger dialect — fail loudly, don't guess.
      fake = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "OracleEnhanced")

      expect { described_class::Triggers.for(fake) }.to raise_error(NotImplementedError, /OracleEnhanced/)
    end
  end
end
