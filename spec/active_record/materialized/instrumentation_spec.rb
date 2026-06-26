# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Instrumentation do
  subject(:view) { define_view("mv_sales_summary", :sales_by_category) }

  describe "read.active_record_materialized" do
    it "reports cache hits with staleness once the view is materialized" do
      seed_items(["a", 10])
      view.rebuild!(confirm: true)

      events = capture_events(described_class::READ) { view.where(category: "a").to_a }

      expect(events.size).to eq(1)
      payload = events.first.payload
      expect(payload).to include(view: view, source: :cache)
      expect(payload[:staleness]).to be_a(Float).and(be >= 0.0)
    end

    it "reports a read-through fallback with nil staleness on a cold view" do
      events = capture_events(described_class::READ) { view.all.to_a }

      expect(events.map { |event| event.payload[:source] }).to eq([:read_through])
      expect(events.first.payload[:staleness]).to be_nil
    end

    it "uses the configured cold-read strategy as the source" do
      stale_view = define_view("mv_stale", :sales_by_category) { cold_read :serve_stale }

      events = capture_events(described_class::READ) { stale_view.all.to_a }

      expect(events.first.payload[:source]).to eq(:serve_stale)
    end

    it "skips the staleness lookup entirely when nobody is subscribed" do
      seed_items(["a", 10])
      view.rebuild!(confirm: true)
      allow(view.metadata).to receive(:last_refreshed_at).and_call_original

      view.where(category: "a").to_a

      expect(view.metadata).not_to have_received(:last_refreshed_at)
    end
  end

  describe "refresh.active_record_materialized" do
    it "times a rebuild and reports the full mode and row count" do
      seed_items(["a", 10], ["b", 20])

      events = capture_events(described_class::REFRESH) { view.rebuild!(confirm: true) }

      expect(events.size).to eq(1)
      payload = events.first.payload
      expect(payload).to include(view: view, operation: :rebuild, mode: :full, row_count: 2, skipped: false)
      expect(payload[:partition_count]).to be_nil
      expect(events.first.duration).to be >= 0.0
    end

    it "reports a summary-delta refresh on a materialized delta-maintainable view" do
      seed_items(["a", 10])
      view.rebuild!(confirm: true)
      record_write(view, "b", 5)

      events = capture_events(described_class::REFRESH) { view.refresh! }

      payload = events.first.payload
      expect(payload).to include(operation: :incremental, mode: :summary_delta, partition_count: 1, skipped: false)
    end

    it "reports a scoped recompute with the partitions it recomputed" do
      # A cold view populates affected partitions via scoped recompute, not summary deltas.
      record_write(view, "a", 10)

      events = capture_events(described_class::REFRESH) { view.refresh! }

      payload = events.first.payload
      expect(payload).to include(operation: :incremental, mode: :scoped_recompute, partition_count: 1, skipped: false)
    end

    it "marks an unmaintainable refresh as skipped" do
      seed_items(["a", 10])
      view.rebuild!(confirm: true)

      events = capture_events(described_class::REFRESH) { view.refresh! }

      expect(events.first.payload).to include(skipped: true)
    end

    it "captures the exception when a refresh fails" do
      record_write(view, "a", 10)
      allow(ActiveRecord::Materialized::IncrementalMaintainer).to receive(:new).and_raise(StandardError, "boom")

      events = capture_events(described_class::REFRESH) do
        expect { view.refresh! }.to raise_error(ActiveRecord::Materialized::Refresher::RefreshError)
      end

      expect(events.first.payload[:exception]).to include("StandardError", "boom")
    end
  end

  describe "maintenance.active_record_materialized" do
    it "reports a summary delta on a materialized delta-maintainable view" do
      seed_items(["a", 10])
      view.rebuild!(confirm: true)

      events = capture_events(described_class::MAINTENANCE) { record_write(view, "b", 5) }

      expect(events.first.payload).to include(
        view: view, table: "items", operation: :create, path: :summary_delta, scope: :scoped, partition_count: 1
      )
    end

    it "reports a scoped recompute on a cold view" do
      events = capture_events(described_class::MAINTENANCE) { record_write(view, "b", 5) }

      expect(events.first.payload).to include(path: :scoped_recompute, scope: :scoped, partition_count: 1)
    end

    it "flags a widen to full recompute when the key cannot be derived" do
      # A change whose payload omits the group key (e.g. a write on a joined table)
      # cannot be scoped, so maintenance widens to a full recompute.
      keyless_change = ActiveRecord::Materialized::WriteChange.new(
        table_name: "items", operation: :create, before: {}, after: { "amount" => 5 }
      )

      events = capture_events(described_class::MAINTENANCE) { view.record_write_change!(keyless_change) }

      expect(events.first.payload).to include(path: :scoped_recompute, scope: :full, partition_count: 0)
    end
  end
end
