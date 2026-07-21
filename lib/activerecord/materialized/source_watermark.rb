# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Per-partition CDC source watermarks: the max applied +source_ts+ for each (view, partition).
    # Two jobs, both opt-in via a +source_ts+ on {Materialized.ingest_change}:
    #
    # - **Suppression** — a redelivered or out-of-order change whose watermark is `<` the partition's
    #   applied watermark is provably redundant (the cache already reflects a strictly-newer state), so
    #   its recompute is skipped. A change at the *same* watermark still applies: a coarse (e.g.
    #   second-granular) +source_ts+ such as Debezium's MySQL +source.ts_ms+ can tie two distinct
    #   commits, so an equal value is not treated as a redelivery. Best-effort and **reconcile-backed**:
    #   the watermark advances at ingest, so a crash before the recompute can over-suppress a partition
    #   until reconciliation (#64) heals it — an optimization over always-recompute, never a correctness
    #   substitute.
    # - **Observability** — {#oldest} reports the view's most-behind partition watermark, so a caller can
    #   compute freshness/lag against its own source clock (in the same unit as +source_ts+).
    #
    # Only the scoped-recompute path (a +change_source :none+ CDC-fed view) carries a watermark; a full
    # recompute (no partition key) is never suppressed. +source_ts+ must be monotonic (non-decreasing)
    # per partition (e.g. a Debezium +source.ts_ms+ or a per-key Kafka offset); ties are safe (only a
    # strictly-older value is suppressed). Mirrors {PartitionState}'s per-partition store.
    #
    # @api private
    class SourceWatermark
      def initialize(view_class)
        @view_class = view_class
      end

      # Drop the delta's partitions that already applied a strictly-newer +source_ts+, and advance the
      # watermark for the survivors — a change at the same +source_ts+ still applies, so a distinct write
      # sharing a coarse (e.g. second-granular) timestamp is never suppressed. A full-partition delta
      # (no key) is returned unchanged — it can't be scoped.
      #
      # @return [MaintenanceDelta, nil] the surviving partitions, or nil when every one was suppressed
      def suppress(source_ts, delta)
        return delta if delta.full_partition?

        ensure_table!
        current = current_watermarks(delta.key_tuples) # one read for the whole decision
        fresh = delta.key_tuples.reject { |tuple| (ts = current[serialize(tuple)]) && ts > source_ts }
        return nil if fresh.empty?

        advance!(fresh, source_ts)
        MaintenanceDelta.scoped(fresh)
      end

      # The oldest applied watermark across the view's partitions that have received a watermarked
      # change (its most-behind such partition), or nil when none have. Subtract from the source clock
      # (same unit as +source_ts+) for lag. A partition maintained only via widen-to-full changes records
      # no watermark and so is not reflected here; a stalled *stream* (no events arriving) is a
      # pipeline-level concern, monitored at the consumer. A read only — never provisions the table.
      #
      # @return [Integer, nil]
      def oldest
        return nil unless SourceWatermarkRecord.table_exists?

        scope.minimum(:source_ts)
      end

      private

      # The stored watermark for each of +tuples+, in one query, as { serialized_key => source_ts }.
      def current_watermarks(tuples)
        scope.where(partition_key: tuples.map { |tuple| serialize(tuple) }).pluck(:partition_key, :source_ts).to_h
      end

      # Advance each partition's watermark to source_ts. +create_or_find_by+ absorbs a concurrent
      # first-insert (the unique index would otherwise raise RecordNotUnique); the guarded +update!+ only
      # moves a watermark forward. Advancement is best-effort (like the feature): a concurrent advance
      # read as stale could briefly regress a watermark, at worst causing a later redundant recompute
      # (never wrong data) — reconciliation is the backstop.
      def advance!(tuples, source_ts)
        tuples.each do |tuple|
          key = serialize(tuple)
          row = SourceWatermarkRecord.create_or_find_by(view_name: view_key, partition_key: key) do |record|
            record.source_ts = source_ts
          end
          row.update!(source_ts: source_ts) if row.source_ts < source_ts
        end
      end

      def scope
        SourceWatermarkRecord.where(view_name: view_key)
      end

      def view_key
        @view_class.view_key
      end

      def serialize(key_tuple)
        key_tuple.map(&:to_s).to_json
      end

      def ensure_table!
        connection = @view_class.connection
        return if SourceWatermarkRecord.table_exists?

        table = ::ActiveRecord::Materialized.configuration.source_watermark_table_name
        connection.create_table(table) do |t|
          t.string :view_name, null: false
          t.string :partition_key, null: false
          t.bigint :source_ts, null: false
          t.timestamps
        end
        connection.add_index(table, %i[view_name partition_key], unique: true)
        SourceWatermarkRecord.reset_column_information
      end
    end
  end
end
