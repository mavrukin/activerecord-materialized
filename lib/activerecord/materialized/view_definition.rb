# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class ViewDefinition
      extend T::Sig

      GROUP_BY_PATTERN = T.let(
        /\bGROUP\s+BY\s+(.+?)(?=\s+\bHAVING\b|\s+\bORDER\s+BY\b|\s+\bLIMIT\b|\s*$)/im,
        Regexp
      )
      WHERE_PATTERN = T.let(/\bWHERE\b/i, Regexp)

      sig { params(source_sql: String).void }
      def initialize(source_sql)
        @source_sql = T.let(source_sql.strip, String)
      end

      sig { returns(T::Boolean) }
      def incrementally_maintainable?
        group_key_columns.any?
      end

      sig { returns(T::Array[String]) }
      def group_key_columns
        @group_key_columns = T.let(@group_key_columns, T.nilable(T::Array[String]))
        @group_key_columns ||= parse_group_key_columns
      end

      sig { params(key_tuples: T::Array[T::Array[String]]).returns(String) }
      def scoped_source_sql(key_tuples)
        raise ArgumentError, "scoped maintenance requires GROUP BY keys" unless incrementally_maintainable?
        raise ArgumentError, "scoped maintenance requires at least one partition key" if key_tuples.empty?

        inject_predicate(build_partition_predicate(key_tuples))
      end

      private

      sig { returns(T::Array[String]) }
      def parse_group_key_columns
        match = @source_sql.match(GROUP_BY_PATTERN)
        return [] unless match

        T.must(match[1]).split(",").map { |column| normalize_column_name(column.strip) }
      end

      sig { params(expression: String).returns(String) }
      def normalize_column_name(expression)
        expression.split(/\s+AS\s+/i).first.to_s.strip
      end

      sig { params(key_tuples: T::Array[T::Array[String]]).returns(String) }
      def build_partition_predicate(key_tuples)
        columns = group_key_columns
        if columns.size == 1
          column = quote_identifier(columns.fetch(0))
          values = key_tuples.map { |tuple| quote_literal(tuple.fetch(0)) }.join(", ")
          "#{column} IN (#{values})"
        else
          column_list = columns.map { |column| quote_identifier(column) }.join(", ")
          tuple_list = key_tuples.map do |tuple|
            "(#{tuple.map { |value| quote_literal(value) }.join(', ')})"
          end.join(", ")
          "(#{column_list}) IN (#{tuple_list})"
        end
      end

      sig { params(predicate: String).returns(String) }
      def inject_predicate(predicate)
        group_match = @source_sql.match(/\bGROUP\s+BY\b/i)
        raise ArgumentError, "materialized_from must include GROUP BY for incremental maintenance" unless group_match

        split_at = group_match.begin(0)
        before_group = T.must(@source_sql[0...split_at]).strip
        from_group = @source_sql[split_at..].to_s

        if before_group.match?(WHERE_PATTERN)
          "#{before_group} AND (#{predicate}) #{from_group}"
        else
          "#{before_group} WHERE #{predicate} #{from_group}"
        end
      end

      sig { params(identifier: String).returns(String) }
      def quote_identifier(identifier)
        if identifier.include?(".")
          table, column = identifier.split(".", 2)
          %("#{table}"."#{column}")
        else
          %("#{identifier}")
        end
      end

      sig { params(value: String).returns(String) }
      def quote_literal(value)
        "'#{value.gsub("'", "''")}'"
      end
    end
  end
end
