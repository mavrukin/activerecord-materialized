# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Tracks which partitions of a cold view have been materialized ("fresh") so
    # a read can decide whether a partition is served from the cache or read
    # through to the source. Warm views are fully materialized and ignore this.
    class PartitionState
      def initialize(view_class)
        @view_class = view_class
      end

      def all_fresh?(key_tuples)
        return false if key_tuples.empty?

        ensure_table!
        @view_class.metadata.ensure_schema! # the epoch subquery reads the metadata table
        serialized = key_tuples.map { |tuple| serialize(tuple) }.uniq
        # Only marks stamped with the current epoch count as fresh — a mark left behind by a populate
        # that raced a reset! (a widen invalidation) carries a superseded generation and is ignored.
        # The epoch is a correlated subquery so this stays ONE round-trip on the keyed cold-read fast path.
        fresh = scope.where(partition_key: serialized, generation: current_generation_scope)
        fresh.count == serialized.size
      end

      # Stamp each partition fresh with +generation+ (the epoch the caller captured before its source
      # read). Overwrites any existing mark's generation, so a re-populate after a reset! re-establishes
      # freshness rather than leaving a stale-epoch row that all_fresh? would forever ignore.
      def mark_fresh!(key_tuples, generation:)
        return if key_tuples.empty?

        ensure_table!
        key_tuples.uniq.each do |tuple|
          record = PartitionRecord.create_or_find_by(view_name: view_key, partition_key: serialize(tuple))
          record.update!(generation: generation) unless record.generation == generation
        end
      end

      def mark_stale!(key_tuples)
        return if key_tuples.empty?

        ensure_table!
        scope.where(partition_key: key_tuples.map { |tuple| serialize(tuple) }).delete_all
      end

      # Invalidate the whole fresh set (a widen recompute whose scope is unknown). Advance the epoch
      # FIRST, then delete the marks: the epoch bump alone invalidates everything (all_fresh? honours
      # only current-epoch marks), so the delete is pure cleanup. Ordering it this way makes reset!
      # crash-safe without a transaction — a crash after the bump but before the delete still leaves the
      # fresh set invalidated (stale-epoch marks are ignored, and a racing populate that captured the
      # pre-bump epoch is ignored too); the leftover rows are reclaimed by the next reset!.
      def reset!
        ensure_table!
        @view_class.metadata.bump_fresh_set_generation!
        scope.delete_all
      end

      # The current fresh-set epoch, read into Ruby. A populate captures this BEFORE its source read and
      # stamps its marks with it, so a widen committing during the read advances the epoch and leaves the
      # mark un-served. (all_fresh? compares against the epoch in-SQL via current_generation_scope.)
      def current_generation
        @view_class.metadata.fresh_set_generation
      end

      # The partition key tuples a query touches, or nil unless the conditions are
      # an exact match on the GROUP BY columns (the only case the fast path serves).
      def self.keys_from(view_class, args)
        conditions = single_hash(args)
        return nil if conditions.nil?

        group_keys = view_class.maintenance_key_columns
        return nil if group_keys.empty?

        value_lists = key_value_lists(conditions, group_keys)
        value_lists.nil? ? nil : cartesian(value_lists)
      end

      def self.single_hash(args)
        return nil unless args.length == 1

        conditions = args.fetch(0)
        conditions.is_a?(Hash) ? conditions : nil
      end

      def self.key_value_lists(conditions, group_keys)
        normalized = conditions.transform_keys(&:to_s)
        return nil unless normalized.keys.sort == group_keys.sort

        group_keys.map { |column| Array(normalized.fetch(column)).map(&:to_s) }
      end

      def self.cartesian(value_lists)
        return nil if value_lists.any?(&:empty?)

        value_lists.reduce([[]]) do |tuples, values|
          tuples.flat_map { |tuple| values.map { |value| tuple + [value] } }
        end
      end

      private

      # The view's current epoch as a one-column relation, so all_fresh? can filter marks by it in a
      # single query (generation IN (SELECT ...)). An absent metadata row yields no match — nothing is
      # fresh — which is correct: partition marks only ever exist once maintenance has created the row.
      def current_generation_scope
        MetadataRecord.where(view_name: view_key).select(:fresh_set_generation)
      end

      def view_key
        @view_class.view_key
      end

      def serialize(key_tuple)
        key_tuple.map(&:to_s).to_json
      end

      def scope
        PartitionRecord.where(view_name: view_key)
      end

      def ensure_table!
        connection = @view_class.connection
        return ensure_generation_column!(connection) if PartitionRecord.table_exists?

        table = ::ActiveRecord::Materialized.partition_table_name
        connection.create_table(table) do |t|
          t.string :view_name, null: false
          t.string :partition_key, null: false
          t.integer :generation, null: false, default: 0
          t.datetime :created_at, null: false
        end
        connection.add_index(table, %i[view_name partition_key], unique: true)
        PartitionRecord.reset_column_information
      end

      # Lazily add the fresh-set epoch column (#120) to a partition table provisioned by an earlier
      # version, so an app migrated from before this column picks it up without a new migration.
      def ensure_generation_column!(connection)
        return if PartitionRecord.column_names.include?("generation")

        connection.add_column(
          ::ActiveRecord::Materialized.partition_table_name, :generation, :integer, null: false, default: 0
        )
        PartitionRecord.reset_column_information
      end
    end
  end
end
