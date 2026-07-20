# frozen_string_literal: true

require_relative "integration_helper"

# Marker module so RSpec/DescribeClass and the spec-file-path convention are met.
module CdcRealCapture; end

# #80 — the literal end-to-end CDC path: observe the database's own change log, DECODE it, and relay
# through ingest_change — with no write-site descriptor synthesis (that is what #70's CdcScenario
# does). This proves the ingestion API consumes exactly what a real log-based CDC consumer
# (Debezium/Maxwell-style) emits. Postgres decodes a test_decoding logical slot; MySQL decodes the
# ROW binlog via mysqlbinlog (gated on the client). SQLite has no server change log and is skipped.
RSpec.describe CdcRealCapture, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      let(:view) { IntegrationSchema.define_view("mv_cdc_real_capture") }
      let(:capture) { CdcCapture.for(profile.capture, table: "arm_line_items", connection: ActiveRecord::Base.connection) }

      before do
        with_adapter!(profile)
        skip("#{profile.label} real capture unavailable — #{capture.unavailable_reason}") unless capture.capturable?
      end

      it "decodes a raw INSERT and DELETE from the change log and converges via ingest_change" do
        seed_line_items(["books", 10], ["games", 20])
        view.rebuild!(confirm: true) # books:10, games:20

        descriptors = capture_from(capture) do
          raw_sql("INSERT INTO arm_line_items (category, amount) VALUES ('books', 5)")
          raw_sql("DELETE FROM arm_line_items WHERE category = 'games'")
        end

        # Decoded from the log (not the write site): a create carries the new-image key, a destroy
        # the old-image key — the latter present only because full row images are logged.
        create = hash_including(operation: :create, after: hash_including("category" => "books"))
        destroy = hash_including(operation: :destroy, before: hash_including("category" => "games"))
        expect(descriptors).to match([create, destroy])

        scopes = maintenance_scopes { descriptors.each { |d| ActiveRecord::Materialized.ingest_change(**d) } }

        expect(scopes.uniq).to eq([:scoped]) # decoded keys kept maintenance scoped (never widened)
        expect(converged?(view)).to be(true)
        expect(view.find_by(category: "books").total_amount).to eq(15) # insert re-aggregated books
      end

      it "decodes a partition-moving UPDATE carrying both images and maintains both partitions" do
        seed_line_items(["games", 20])
        view.rebuild!(confirm: true)

        descriptors = capture_from(capture) do
          raw_sql("UPDATE arm_line_items SET category = 'toys' WHERE category = 'games'")
        end

        # A full-image UPDATE decodes to both the old and the new partition key.
        update = hash_including(operation: :update, before: hash_including("category" => "games"),
                                after: hash_including("category" => "toys"))
        expect(descriptors).to match([update])

        scopes = maintenance_scopes { descriptors.each { |d| ActiveRecord::Materialized.ingest_change(**d) } }

        expect(scopes.uniq).to eq([:scoped]) # both partitions maintained in place, no full recompute
        expect(converged?(view)).to be(true)
        expect(view.find_by(category: "games")).to be_nil # old partition emptied
        expect(view.find_by(category: "toys").total_amount).to eq(20) # new partition gained the row
      end

      # start capture → run the raw writes → drain the decoded descriptors → always drop the slot.
      def capture_from(strategy)
        strategy.start
        yield
        strategy.drain
      ensure
        strategy.stop
      end

      def raw_sql(sql)
        ActiveRecord::Base.connection.execute(sql)
      end

      # The :scope (:scoped / :full) of each maintenance the block drives, via the maintenance
      # instrumentation — so a test can assert the decoded keys kept maintenance partition-scoped.
      def maintenance_scopes(&)
        scopes = []
        callback = ->(*args) { scopes << ActiveSupport::Notifications::Event.new(*args).payload[:scope] }
        ActiveSupport::Notifications.subscribed(callback, "maintenance.active_record_materialized", &)
        scopes
      end
    end
  end
end
