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
    #     "source" => { "table" => "line_items", ... } }
    #
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
      # @return [Hash, nil] +{ table:, operation:, before:, after: }+ for {Materialized.ingest_change},
      #   or +nil+ for a tombstone (nothing to relay)
      # @raise [ArgumentError] for a non-tombstone envelope with no +op+ (not a Debezium change event,
      #   or not unwrapped), an unsupported +op+, or when the target table can't be determined
      def self.to_change_descriptor(envelope, table = nil)
        return nil if envelope.nil? # Kafka tombstone

        change = unwrap(envelope)
        op = fetch(change, "op")
        raise ArgumentError, "not a Debezium change envelope (no op)" if op.nil?

        { table: resolve_table(table, change), operation: operation_for(op),
          before: fetch(change, "before"), after: fetch(change, "after") }
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

      def self.operation_for(op_code)
        OPERATIONS.fetch(op_code.to_s) do
          raise ArgumentError, "unsupported Debezium op #{op_code.inspect} (expected one of c, r, u, d)"
        end
      end
      private_class_method :operation_for

      def self.resolve_table(table, change)
        resolved = table.presence || fetch(fetch(change, "source"), "table")
        return resolved.to_s if resolved.present?

        raise ArgumentError, "could not determine the table (pass table or include source.table in the envelope)"
      end
      private_class_method :resolve_table
    end
  end
end
