# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Refresher
      class TableQuoter
        extend T::Sig

        sig { params(view_class: ViewClass).void }
        def initialize(view_class)
          @view_class = view_class
        end

        sig { params(name: String).returns(String) }
        def quote(name)
          @view_class.connection.quote_table_name(name)
        end

        sig { params(connection: Connection, table_name: String).returns(T::Boolean) }
        def exists?(connection, table_name)
          connection.data_source_exists?(table_name)
        end
      end

      module Strategies
        extend T::Sig

        module_function

        sig do
          params(
            quoter: TableQuoter,
            connection: Connection,
            table_name: String,
            source_sql: String
          ).returns(Integer)
        end
        def atomic_swap!(quoter, connection, table_name, source_sql)
          temp_table = "#{table_name}_refresh_#{SecureRandom.hex(4)}"
          old_table = "#{table_name}_old_#{SecureRandom.hex(4)}"

          connection.execute("CREATE TABLE #{quoter.quote(temp_table)} AS #{source_sql}")
          row_count = connection.select_value("SELECT COUNT(*) FROM #{quoter.quote(temp_table)}").to_i

          swap_tables!(quoter, connection, table_name, temp_table, old_table)
          row_count
        end

        sig do
          params(
            quoter: TableQuoter,
            connection: Connection,
            table_name: String,
            temp_table: String,
            old_table: String
          ).void
        end
        def swap_tables!(quoter, connection, table_name, temp_table, old_table)
          connection.transaction do
            rename_if_present!(quoter, connection, table_name, old_table)
            connection.execute(
              "ALTER TABLE #{quoter.quote(temp_table)} RENAME TO #{quoter.quote(table_name)}"
            )
            drop_if_present!(quoter, connection, old_table)
          end
        end

        sig do
          params(
            quoter: TableQuoter,
            connection: Connection,
            table_name: String,
            source_sql: String
          ).returns(Integer)
        end
        def truncate_insert!(quoter, connection, table_name, source_sql)
          ensure_cache_table!(quoter, connection, table_name, source_sql)
          quoted = quoter.quote(table_name)
          connection.execute("DELETE FROM #{quoted}")
          connection.execute("INSERT INTO #{quoted} #{source_sql}")
          connection.select_value("SELECT COUNT(*) FROM #{quoted}").to_i
        end

        sig do
          params(
            quoter: TableQuoter,
            connection: Connection,
            table_name: String,
            source_sql: String
          ).void
        end
        def ensure_cache_table!(quoter, connection, table_name, source_sql)
          return if quoter.exists?(connection, table_name)

          connection.execute(
            "CREATE TABLE #{quoter.quote(table_name)} AS #{source_sql} WHERE 1=0"
          )
        end

        sig do
          params(
            quoter: TableQuoter,
            connection: Connection,
            table_name: String,
            renamed_table: String
          ).void
        end
        def rename_if_present!(quoter, connection, table_name, renamed_table)
          return unless quoter.exists?(connection, table_name)

          connection.execute(
            "ALTER TABLE #{quoter.quote(table_name)} RENAME TO #{quoter.quote(renamed_table)}"
          )
        end

        sig { params(quoter: TableQuoter, connection: Connection, table_name: String).void }
        def drop_if_present!(quoter, connection, table_name)
          return unless quoter.exists?(connection, table_name)

          connection.execute("DROP TABLE IF EXISTS #{quoter.quote(table_name)}")
        end
      end
    end
  end
end
