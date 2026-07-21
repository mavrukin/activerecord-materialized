# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Maps a Debezium change envelope to an {Materialized.ingest_change} descriptor. Pure and
    # dependency-free: no Kafka / Debezium / Kafka-Connect runtime — just a mapping over the decoded
    # envelope hash a consumer already holds. It removes the boilerplate (and the easy-to-miss cases:
    # snapshot reads, tombstones, the nested/unwrapped shapes) every consumer otherwise hand-writes.
    #
    # The envelope shape (a Debezium MySQL/Postgres connector event, whether or not the
    # ExtractNewRecordState "unwrap" SMT has been applied — a nested +payload+ is unwrapped here):
    #
    #   { "op" => "u",
    #     "before" => { "id" => 1, "category" => "books", ... },   # full row image (see below)
    #     "after"  => { "id" => 1, "category" => "games", ... },
    #     "ts_ms"  => 1710000000000,                               # connector processing time (unused)
    #     "source" => { "table" => "line_items", "ts_ms" => 1710000000000, ... } }
    #
    # The +source.ts_ms+ (the DB commit time, monotonic within a source) is forwarded as the +source_ts+
    # watermark, so a consumer relaying envelopes gets out-of-order suppression + freshness
    # ({SourceWatermark}) for free. The top-level +ts_ms+ is a *different* clock (the connector's
    # processing time), so it is not used as a fallback — mixing clocks would break monotonicity.
    # Correct **partition-moving** updates require a full +before+ image (+binlog-row-image=FULL+ on
    # MySQL, +REPLICA IDENTITY FULL+ on Postgres); with only the primary key in +before+, the old
    # partition is under-maintained until reconciliation heals it. See +docs/out-of-band-writes.md+
    # and the CDC section of the README. This adapter is Debezium-specific; a Maxwell/other envelope
    # (no +op+) raises rather than being silently dropped.
    module DebeziumEnvelope
      # Debezium +op+ → the gem's operation. A snapshot read ("r") is a create; "d" is a destroy.
      OPERATIONS = { "c" => :create, "r" => :create, "u" => :update, "d" => :destroy }.freeze
      private_constant :OPERATIONS

      # @param envelope [Hash, nil] a decoded Debezium change event (string or symbol keys), or +nil+
      #   for a Kafka tombstone (the null-value message emitted after a delete for log compaction)
      # @param table [String, Symbol, nil] target-table override; defaults to the envelope's +source.table+
      # @return [Hash, nil] +{ table:, operation:, before:, after: }+ (plus +source_ts:+ when the
      #   envelope carries a usable +ts_ms+) for {Materialized.ingest_change}, or +nil+ for a
      #   tombstone (nothing to relay)
      # @raise [ArgumentError] for a non-tombstone envelope with no +op+ (not a Debezium change event,
      #   or not unwrapped), an unsupported +op+, or when the target table can't be determined
      def self.to_change_descriptor(envelope, table = nil)
        return nil if envelope.nil? # Kafka tombstone

        change = unwrap(envelope)
        op = fetch(change, "op")
        raise ArgumentError, "not a Debezium change envelope (no op)" if op.nil?

        descriptor = { table: resolve_table(table, change), operation: operation_for(op),
                       before: fetch(change, "before"), after: fetch(change, "after") }
        ts = source_ts(change)
        ts ? descriptor.merge(source_ts: ts) : descriptor
      end

      # Debezium's default envelope nests the change under +payload+; the ExtractNewRecordState SMT
      # unwraps it to the top level. Accept either by unwrapping a +payload+ that carries the +op+.
      def self.unwrap(envelope)
        payload = fetch(envelope, "payload")
        payload.is_a?(Hash) && fetch(payload, "op") ? payload : envelope
      end
      private_class_method :unwrap

      # Read a key from an envelope that may use string or symbol keys, without deep-copying the hash
      # (before/after images can be wide, and are copied again downstream by WriteChange).
      def self.fetch(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_sym]
      end
      private_class_method :fetch

      # A field from the envelope's +source+ metadata block (string/symbol keys), or nil if absent.
      def self.source_field(change, key)
        fetch(fetch(change, "source"), key)
      end
      private_class_method :source_field

      def self.operation_for(op_code)
        OPERATIONS.fetch(op_code.to_s) do
          raise ArgumentError, "unsupported Debezium op #{op_code.inspect} (expected one of c, r, u, d)"
        end
      end
      private_class_method :operation_for

      def self.resolve_table(table, change)
        resolved = table.presence || source_field(change, "table")
        return resolved.to_s if resolved.present?

        raise ArgumentError, "could not determine the table (pass table or include source.table in the envelope)"
      end
      private_class_method :resolve_table

      # The per-partition source watermark for this change: Debezium's +source.ts_ms+ (the DB commit
      # time, monotonic within a source). Only an Integer is forwarded — a missing or non-integer value
      # yields no watermark, so the change is maintained exactly as before (see {SourceWatermark}). The
      # top-level +ts_ms+ (the connector's *processing* wall-clock) is intentionally NOT a fallback: it
      # is a different clock, so mixing the two per partition would break the monotonicity suppression
      # relies on. A real Debezium change event always carries +source.ts_ms+.
      def self.source_ts(change)
        ts = source_field(change, "ts_ms")
        ts if ts.is_a?(Integer)
      end
      private_class_method :source_ts
    end
  end
end
