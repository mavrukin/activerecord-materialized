# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Refresher
      extend T::Sig

      class RefreshError < StandardError; end

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
        @metadata = T.let(nil, T.nilable(Metadata))
      end

      sig { params(force: T::Boolean).returns(RefreshResult) }
      def refresh!(force: false)
        raise RefreshError, "#{view_class.name} is already refreshing" if metadata.refreshing? && !force

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        metadata.mark_refreshing!
        view_class.run_refresh_callbacks(:before_refresh)

        row_count = perform_refresh!

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        metadata.mark_refreshed!(row_count: row_count, duration_ms: duration_ms)
        view_class.run_refresh_callbacks(:after_refresh)

        RefreshResult.new(
          view_class: view_class,
          row_count: row_count,
          duration_ms: duration_ms,
          refreshed_at: metadata.last_refreshed_at
        )
      rescue StandardError => e
        metadata.mark_failed!(e)
        raise RefreshError, "Failed to refresh #{view_class.name}: #{e.message}", e.backtrace
      end

      private

      sig { returns(Metadata) }
      def metadata
        @metadata ||= view_class.metadata
      end

      sig { returns(Integer) }
      def perform_refresh!
        connection = view_class.connection
        source_sql = view_class.resolved_source_sql
        table_name = view_class.table_name

        if ::ActiveRecord::Materialized.atomic_swap_refresh?
          refresh_with_atomic_swap!(connection, table_name, source_sql)
        else
          refresh_with_truncate_insert!(connection, table_name, source_sql)
        end
      end

      sig { params(connection: Connection, table_name: String, source_sql: String).returns(Integer) }
      def refresh_with_atomic_swap!(connection, table_name, source_sql)
        temp_table = "#{table_name}_refresh_#{SecureRandom.hex(4)}"
        old_table = "#{table_name}_old_#{SecureRandom.hex(4)}"

        connection.execute("CREATE TABLE #{quote_table(temp_table)} AS #{source_sql}")
        row_count = connection.select_value("SELECT COUNT(*) FROM #{quote_table(temp_table)}").to_i

        connection.transaction do
          if table_exists?(connection, table_name)
            connection.execute("ALTER TABLE #{quote_table(table_name)} RENAME TO #{quote_table(old_table)}")
          end

          connection.execute("ALTER TABLE #{quote_table(temp_table)} RENAME TO #{quote_table(table_name)}")
          connection.execute("DROP TABLE IF EXISTS #{quote_table(old_table)}") if table_exists?(connection, old_table)
        end

        row_count
      end

      sig { params(connection: Connection, table_name: String, source_sql: String).returns(Integer) }
      def refresh_with_truncate_insert!(connection, table_name, source_sql)
        ensure_cache_table!(connection, table_name, source_sql)
        connection.execute("DELETE FROM #{quote_table(table_name)}")
        connection.execute("INSERT INTO #{quote_table(table_name)} #{source_sql}")
        connection.select_value("SELECT COUNT(*) FROM #{quote_table(table_name)}").to_i
      end

      sig { params(connection: Connection, table_name: String, source_sql: String).void }
      def ensure_cache_table!(connection, table_name, source_sql)
        return if table_exists?(connection, table_name)

        connection.execute("CREATE TABLE #{quote_table(table_name)} AS #{source_sql} WHERE 1=0")
      end

      sig { params(connection: Connection, table_name: String).returns(T::Boolean) }
      def table_exists?(connection, table_name)
        connection.data_source_exists?(table_name)
      end

      sig { params(name: String).returns(String) }
      def quote_table(name)
        view_class.connection.quote_table_name(name)
      end
    end
  end
end
