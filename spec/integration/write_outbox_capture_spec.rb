# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module WriteOutboxCapture; end

# #68 — the trigger/outbox change source, end-to-end on each real engine. Database triggers capture
# raw writes that bypass ActiveRecord entirely (here: a literal INSERT/UPDATE/DELETE via #execute)
# into the outbox, and drain_write_outbox! relays them through the ingestion API so the view is
# maintained. This is what proves the per-adapter trigger DDL (Postgres function + TG_OP trigger;
# MySQL/SQLite one trigger per op) is correct against the real database, not just well-formed.
RSpec.describe WriteOutboxCapture, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        with_adapter!(profile)
        reset_outbox! # clear any outbox residue from a prior example on this adapter
      end

      it "relays raw out-of-band INSERT and DELETE into scoped maintenance" do
        view = IntegrationSchema.define_view("mv_wob_scoped")
        seed_line_items(["books", 10], ["games", 20])
        view.rebuild!(confirm: true) # cache: books => 10, games => 20
        install_outbox_triggers!

        # Writes that bypass ActiveRecord entirely — no callbacks, no ingestion call.
        raw_sql("INSERT INTO arm_line_items (category, amount) VALUES ('books', 5)")
        raw_sql("DELETE FROM arm_line_items WHERE category = 'games'")
        expect(view.find_by(category: "books").total_amount).to eq(10) # invisible until drained

        expect(ActiveRecord::Materialized.drain_write_outbox!).to eq(2) # both raw writes captured + relayed
        expect(view.find_by(category: "books").total_amount).to eq(15)  # insert re-aggregated the books partition
        expect(view.find_by(category: "games")).to be_nil               # delete emptied the games partition
      end

      it "relays a partition-moving update into both the old and the new partition" do
        view = IntegrationSchema.define_view("mv_wob_move")
        seed_line_items(["books", 10])
        view.rebuild!(confirm: true) # cache: books => 10
        install_outbox_triggers!

        # An update that changes the GROUP BY key moves the row between partitions.
        raw_sql("UPDATE arm_line_items SET category = 'games' WHERE category = 'books'")

        ActiveRecord::Materialized.drain_write_outbox!
        # The update captured both key images, so both partitions are recomputed:
        expect(view.find_by(category: "books")).to be_nil               # old partition emptied
        expect(view.find_by(category: "games").total_amount).to eq(10)  # new partition gained the row
      end

      def install_outbox_triggers!
        ActiveRecord::Materialized::WriteOutbox.install_triggers!(:arm_line_items, key_columns: [:category])
      end

      def raw_sql(sql)
        ActiveRecord::Base.connection.execute(sql)
      end

      def reset_outbox!
        # Cross-example isolation: provision! force-recreates the dependency tables but not the outbox,
        # so clear any residue from a prior example on this adapter. (The column-cache refresh on
        # (re)create lives in WriteOutbox.ensure_table!, so it isn't needed here.)
        outbox = ActiveRecord::Materialized::WriteOutbox.table_name
        ActiveRecord::Materialized::WriteOutboxRecord.delete_all if
          ActiveRecord::Base.connection.data_source_exists?(outbox)
      end
    end
  end
end
