# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class ChangeKeyExtractor
      extend T::Sig

      INSERT_COLUMNS_PATTERN = T.let(
        /\A\s*INSERT\s+(?:OR\s+\w+\s+)?INTO\s+.+?\((?<columns>[^)]+)\)\s*VALUES\s*(?<values>.+)/im,
        Regexp
      )
      WHERE_EQUALITY_PATTERN = T.let(
        /(?<column>(?:`[^`]+`|"[^"]+"|\w+(?:\.\w+)?))\s*=\s*(?<value>'(?:''|[^'])*'|"(?:[^"]|"")*"|\d+(?:\.\d+)?)/i,
        Regexp
      )

      sig { params(sql: String, group_key_columns: T::Array[String]).void }
      def initialize(sql, group_key_columns)
        @sql = T.let(sql.strip, String)
        @group_key_columns = group_key_columns
        @normalized_group_keys = T.let(
          group_key_columns.map { |column| normalize_column_name(column) },
          T::Array[String]
        )
      end

      sig { returns(MaintenanceDelta) }
      def extract
        return MaintenanceDelta.full_partition if @group_key_columns.empty?
        return extract_insert if insert?
        return extract_delete if delete?
        return extract_update if update?

        MaintenanceDelta.full_partition
      end

      private

      sig { returns(T::Boolean) }
      def insert?
        @sql.match?(/\A\s*INSERT\b/i)
      end

      sig { returns(T::Boolean) }
      def delete?
        @sql.match?(/\A\s*DELETE\b/i)
      end

      sig { returns(T::Boolean) }
      def update?
        @sql.match?(/\A\s*UPDATE\b/i)
      end

      sig { returns(MaintenanceDelta) }
      def extract_insert
        match = @sql.match(INSERT_COLUMNS_PATTERN)
        return MaintenanceDelta.full_partition unless match

        columns = T.must(match[:columns]).split(",").map { |column| normalize_column_name(column.strip) }
        values_clause = T.must(match[:values])
        tuples = values_clause.scan(/\(([^)]+)\)/).filter_map do |row|
          row_values = T.must(row[0]).split(",").map { |value| unquote_literal(value.strip) }
          map_row_to_key_tuple(columns, row_values)
        end

        return MaintenanceDelta.full_partition if tuples.empty?

        MaintenanceDelta.scoped(tuples.uniq)
      end

      sig { returns(MaintenanceDelta) }
      def extract_delete
        where_clause = extract_where_clause
        return MaintenanceDelta.full_partition if where_clause.nil?

        tuples = equality_tuples(where_clause)
        tuples.empty? ? MaintenanceDelta.full_partition : MaintenanceDelta.scoped(tuples.uniq)
      end

      sig { returns(MaintenanceDelta) }
      def extract_update
        where_clause = extract_where_clause
        set_clause = extract_set_clause
        tuples = T.let([], T::Array[T::Array[String]])

        tuples.concat(equality_tuples(where_clause)) if where_clause
        tuples.concat(equality_tuples(set_clause)) if set_clause

        tuples.empty? ? MaintenanceDelta.full_partition : MaintenanceDelta.scoped(tuples.uniq)
      end

      sig { params(columns: T::Array[String], values: T::Array[String]).returns(T.nilable(T::Array[String])) }
      def map_row_to_key_tuple(columns, values)
        @normalized_group_keys.map do |group_key|
          index = columns.index(group_key)
          return nil if index.nil?

          values.fetch(index)
        end
      end

      sig { params(clause: T.nilable(String)).returns(T::Array[T::Array[String]]) }
      def equality_tuples(clause)
        return [] if clause.nil?

        clause.scan(WHERE_EQUALITY_PATTERN).filter_map do |match|
          column = normalize_column_name(T.must(match[0]))
          next unless @normalized_group_keys.include?(column)

          [unquote_literal(T.must(match[1]))]
        end
      end

      sig { returns(T.nilable(String)) }
      def extract_where_clause
        match = @sql.match(/\bWHERE\s+(.+?)(?:\s+\bORDER\s+BY\b|\s+\bLIMIT\b|\s*$)/im)
        return nil unless match

        T.must(match.captures.first).strip
      end

      sig { returns(T.nilable(String)) }
      def extract_set_clause
        match = @sql.match(/\bSET\s+(.+?)\s+\bWHERE\b/i)
        return nil unless match

        T.must(match.captures.first).strip
      end

      sig { params(column: String).returns(String) }
      def normalize_column_name(column)
        column.delete_prefix("`").delete_suffix("`").delete_prefix('"').delete_suffix('"').split(".").last.to_s
      end

      sig { params(literal: String).returns(String) }
      def unquote_literal(literal)
        if literal.start_with?("'")
          T.must(literal[1..-2]).gsub("''", "'")
        elsif literal.start_with?('"')
          T.must(literal[1..-2]).gsub('""', '"')
        else
          literal
        end
      end
    end
  end
end
