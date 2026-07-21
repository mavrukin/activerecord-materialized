# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # A committed write to a dependency table, captured as full before/after
    # attribute snapshots (string-keyed). Snapshots are complete — not just the
    # changed columns — so maintenance can compute deltas even when the GROUP BY
    # key or a summed column did not change.
    class WriteChange
      # A snapshot supplied to {from_descriptor}/{Materialized.ingest_change}: keys
      # may be strings or symbols and are normalized to strings.

      OPERATIONS = %i[create update destroy].freeze
      EMPTY_ATTRIBUTES = {}.freeze

      attr_reader :table_name, :operation, :before, :after, :source_ts

      def initialize(table_name:, operation:, before:, after:, source_ts: nil)
        @table_name = table_name
        @operation = operation
        @before = before
        @after = after
        @source_ts = source_ts # optional monotonic CDC watermark (e.g. Debezium ts_ms); nil for in-app writes
      end

      def self.from_record(record, operation)
        table_name = record.class.table_name
        case operation.to_sym
        when :create
          from_descriptor(table_name: table_name, operation: :create, after: record.attributes)
        when :update
          from_descriptor(table_name: table_name, operation: :update,
                          before: old_attributes(record), after: record.attributes)
        when :destroy
          # attributes_in_database is emptied once the row is gone; use in-memory attributes.
          from_descriptor(table_name: table_name, operation: :destroy, before: record.attributes)
        else
          raise_unsupported_operation!(operation)
        end
      end

      # Builds a change from a normalized descriptor rather than an ActiveRecord
      # record — the seam a CDC / external change stream feeds. Supply full
      # +before+/+after+ images when available, or +key_attributes+ (the GROUP BY
      # columns) to scope maintenance to a partition; with neither — or a partial
      # image that cannot identify every affected partition — it widens to a full
      # recompute. Snapshot keys may be strings or symbols; an unknown operation is
      # rejected.
      def self.from_descriptor(table_name:, operation:, key_attributes: nil, before: nil, after: nil)
        op = operation.to_sym
        raise_unsupported_operation!(operation) unless OPERATIONS.include?(op)

        resolved_before, resolved_after = snapshots_for(op, key_attributes, before, after)
        new(table_name: table_name, operation: op,
            before: stringify_keys(resolved_before), after: stringify_keys(resolved_after))
      end

      # A copy of this change stamped with a CDC source watermark. Kept off {from_descriptor} so its
      # (public) keyword list stays within the argument-count limit; {Materialized.ingest_change}
      # applies it. See {SourceWatermark}.
      #
      # @param source_ts [Integer] a monotonic per-partition source watermark
      # @return [WriteChange]
      def with_source_ts(source_ts)
        self.class.new(table_name: table_name, operation: operation,
                       before: before, after: after, source_ts: source_ts)
      end

      # Full pre-update attributes: current values with changed columns reverted.
      def self.old_attributes(record)
        attributes = stringify_keys(record.attributes)
        record.saved_changes.each_pair { |column, (old_value, _new_value)| attributes[column.to_s] = old_value }
        attributes
      end

      # Resolves the before/after snapshots to record for a descriptor. A create
      # only affects its new partition and a destroy only its old one; an update
      # can move a row between partitions, so both must be recomputed — when the
      # descriptor cannot identify both (only a partial image, no keys) it widens
      # (empty snapshots => full recompute) rather than silently under-scoping.
      def self.snapshots_for(operation, key_attributes, before, after)
        keys = key_attributes.presence
        case operation
        when :create then [EMPTY_ATTRIBUTES, first_present(after, keys)]
        when :destroy then [first_present(before, keys), EMPTY_ATTRIBUTES]
        else update_snapshots(before.presence, after.presence, keys)
        end
      end

      # The affected partition's key image, from the row image or the key columns.
      def self.first_present(image, keys)
        image.presence || keys || EMPTY_ATTRIBUTES
      end

      # An update recomputes both the old and new partition; it scopes only when
      # both are derivable (full images, or key columns for an in-place change) and
      # otherwise widens to a full recompute rather than under-scoping.
      def self.update_snapshots(before, after, keys)
        return [before, after] if before && after
        return [keys, keys] if keys

        [EMPTY_ATTRIBUTES, EMPTY_ATTRIBUTES]
      end

      def self.raise_unsupported_operation!(operation)
        raise ArgumentError, "unsupported write operation: #{operation}"
      end

      def self.stringify_keys(values)
        values.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end

      private_class_method :old_attributes, :snapshots_for, :first_present, :update_snapshots,
                           :raise_unsupported_operation!, :stringify_keys
      private_constant :OPERATIONS, :EMPTY_ATTRIBUTES
    end
  end
end
