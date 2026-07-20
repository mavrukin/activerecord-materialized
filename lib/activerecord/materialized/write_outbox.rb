# frozen_string_literal: true

require "json"

module ActiveRecord
  module Materialized
    # The trigger/outbox change source — the completeness layer for writes that bypass **both**
    # ActiveRecord callbacks and the ingestion API: raw SQL from a console, a bulk backfill,
    # another service writing the shared database. Database triggers on a dependency table capture
    # the changed partition keys into a durable outbox table, and {.drain!} relays them through the
    # ingestion API ({Materialized.ingest_change}) so the view is maintained exactly as it would be
    # for an ActiveRecord write. See +docs/out-of-band-writes.md+.
    #
    # Capture is *scoped*: each trigger records only the configured key columns (the GROUP BY keys),
    # as JSON, in +key_before+ (the OLD image) and/or +key_after+ (the NEW image). That is precisely
    # what {WriteChange.from_descriptor} needs to scope maintenance to the affected partition(s) —
    # and, for an update that moves a row between partitions, to maintain both the old and the new.
    #
    # This is deliberately not the default change source: triggers are DDL a host app opts into
    # (via the +activerecord_materialized:outbox+ generator) for the tables where out-of-band writes
    # actually happen. Drift detection (#62) + +reconcile_stale!+ remain the time-bounded backstop.
    module WriteOutbox
      module_function

      # @return [String] the outbox table name (configurable via +config.write_outbox_table_name+)
      def table_name
        ActiveRecord::Materialized.configuration.write_outbox_table_name
      end

      # Lazily provision the outbox table, mirroring {Metadata::Schema}. Idempotent.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [void]
      def ensure_table!(connection = ActiveRecord::Base.connection)
        return if connection.data_source_exists?(table_name)

        connection.create_table(table_name) do |t|
          t.string :source_table, null: false # the dependency table that was written
          t.string :operation, null: false # one of WriteChange::OPERATIONS ("create"/"update"/"destroy")
          t.text :key_before # JSON of the OLD-image key columns (destroy/update); NULL on create
          t.text :key_after # JSON of the NEW-image key columns (create/update); NULL on destroy
          t.datetime :created_at, null: false
        end
        WriteOutboxRecord.reset_column_information # mirror Metadata::Schema: drop any stale column cache
      end

      # Install AFTER INSERT/UPDATE/DELETE triggers on +table+ that append the +key_columns+ values to
      # the outbox on every write — including raw SQL that never touches ActiveRecord. Idempotent:
      # re-installing drops and recreates. Portable across the gem's adapters (SQLite/MySQL/Postgres);
      # the generated migration runs this so the correct dialect is emitted at migrate time.
      #
      # @param table [String, Symbol] the dependency table to watch
      # @param key_columns [Array<String, Symbol>] the GROUP BY key columns to capture (empty for an
      #   un-grouped/global view — every write then relays an empty image, widening to a full recompute)
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [void]
      def install_triggers!(table, key_columns:, connection: ActiveRecord::Base.connection)
        ensure_table!(connection)
        Triggers.for(connection).install!(connection, table.to_s, Array(key_columns).map(&:to_s))
      end

      # Remove the triggers (and, on Postgres, the trigger function) installed by {.install_triggers!}.
      #
      # @param table [String, Symbol]
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [void]
      def uninstall_triggers!(table, connection: ActiveRecord::Base.connection)
        Triggers.for(connection).uninstall!(connection, table.to_s)
      end

      # Rows relayed per internal batch, so draining a large backlog (a bulk backfill / a period
      # the drain wasn't running) stays bounded in memory instead of materializing the whole outbox.
      DRAIN_BATCH_SIZE = 1_000
      private_constant :DRAIN_BATCH_SIZE

      # Relay pending outbox rows through the ingestion API, in write order, deleting each after it is
      # successfully relayed. Run from a poller, cron, or background job. Properties:
      #
      # - **Bounded memory.** Rows are relayed in batches of {DRAIN_BATCH_SIZE}, so even a huge backlog
      #   (the bulk-backfill case) drains without loading the whole outbox at once.
      # - **At-least-once.** A row is deleted only after its relay succeeds, so a crash mid-drain
      #   re-relays the not-yet-deleted rows next pass — safe, since {Materialized.ingest_change} is
      #   convergent (scoped recompute is idempotent).
      # - **Per-row isolation.** A relay that raises (e.g. a view whose scoped recompute fails) leaves
      #   only that row in the outbox for retry and is skipped for the rest of this pass, so one poison
      #   row can't block the writes queued behind it (mirrors {Reconciler}'s per-view isolation).
      #
      # A no-op (returns 0) before any triggers are installed, so a scheduled drain is safe to run even
      # if the +outbox+ migration hasn't been applied yet.
      #
      # @param limit [Integer, nil] max rows to attempt this pass (nil = drain everything reachable)
      # @return [Integer] the number of outbox rows successfully relayed and deleted
      def drain!(limit: nil)
        return 0 unless WriteOutboxRecord.connection.data_source_exists?(table_name)

        drained = 0
        attempted = 0
        failed_ids = []
        loop do
          take = limit ? [limit - attempted, DRAIN_BATCH_SIZE].min : DRAIN_BATCH_SIZE
          break if take <= 0

          rows = pending_rows(failed_ids, take)
          break if rows.empty?

          attempted += rows.size
          relayed_count, failed = relay_and_delete(rows)
          drained += relayed_count
          failed_ids.concat(failed)
        end
        drained
      end

      # The next batch of pending rows in write (id) order, excluding rows that already failed to relay
      # this pass (so a poison row is retried once per drain, not re-read on every internal batch).
      def pending_rows(failed_ids, take)
        scope = WriteOutboxRecord.order(:id).limit(take)
        scope = scope.where.not(id: failed_ids) if failed_ids.any?
        scope.to_a
      end
      private_class_method :pending_rows

      # Relay each row independently, delete the successfully-relayed ones, and return
      # [relayed_count, failed_ids]. A relay that raises leaves its row in the outbox for retry and is
      # skipped for the rest of the pass; the failing view already records its error on its own
      # metadata, and we log so the isolation isn't silent — one poison row can't block the batch.
      def relay_and_delete(rows)
        relayed = []
        failed = []
        rows.each do |row|
          relay(row)
          relayed << row.id
        rescue StandardError => e
          failed << row.id
          log_relay_failure(row, e)
        end
        WriteOutboxRecord.where(id: relayed).delete_all if relayed.any?
        [relayed.size, failed]
      end
      private_class_method :relay_and_delete

      def log_relay_failure(row, error)
        ActiveRecord::Base.logger&.warn(
          "[activerecord-materialized] WriteOutbox.drain! left outbox row #{row.id} " \
          "(#{row.source_table}/#{row.operation}) for retry: #{error.class}: #{error.message}"
        )
      end
      private_class_method :log_relay_failure

      # Relay a single outbox row through the ingestion API. The stored key columns become the
      # before/after images {WriteChange.from_descriptor} scopes on: after-only for a create, before-only
      # for a destroy, both for an update (so a partition-moving update maintains old and new).
      #
      # @param row [WriteOutboxRecord]
      # @return [void]
      def relay(row)
        ActiveRecord::Materialized.ingest_change(
          table: row.source_table,
          operation: row.operation.to_sym,
          before: parse_image(row.key_before),
          after: parse_image(row.key_after)
        )
      end
      private_class_method :relay

      # @return [Hash, nil] the parsed key-column image, or nil when the column is NULL for this op
      def parse_image(json)
        json.nil? ? nil : JSON.parse(json)
      end
      private_class_method :parse_image

      # Cross-engine trigger DDL. Postgres captures all three operations in one trigger function
      # (branching on +TG_OP+); MySQL and SQLite need one single-operation trigger apiece. All three
      # dialects share the same outbox shape and the same scoped-key JSON, built by {SharedSql}.
      module Triggers
        module_function

        # @return [Module] the adapter-specific builder for +connection+
        # @raise [NotImplementedError] for an unsupported adapter
        def for(connection)
          case connection.adapter_name
          when /postg/i then PostgreSQL
          when /mysql|trilogy|maria/i then MySQL
          when /sqlite/i then SQLite
          else
            raise NotImplementedError,
                  "activerecord-materialized write-outbox triggers are not supported for adapter " \
                  "#{connection.adapter_name.inspect}"
          end
        end

        # One operation's contribution to a trigger: the identifier suffix, the DML event, the
        # {WriteChange} operation name, and the already-built +key_before+/+key_after+ SQL expressions
        # (a JSON constructor or the literal "NULL"). Bundled as a value object so the per-op
        # single-trigger dialects (SQLite/MySQL) share one construction path.
        Op = Data.define(:suffix, :event, :operation, :before, :after)

        # Dialect-agnostic SQL fragments: identifier naming, the scoped-key JSON expression, the
        # per-operation descriptors, and the shared +INSERT INTO outbox ... VALUES+ every body wraps.
        module SharedSql
          module_function

          # Base identifier for a table's triggers/function. "arm_wob" = activerecord-materialized
          # write-outbox; the +_ins+/+_upd+/+_del+/+_fn+ suffixes stay within adapter identifier limits.
          def trigger_base(table)
            "#{table}_arm_wob"
          end

          # A JSON object of the key columns read from the +row_alias+ pseudo-record (NEW or OLD),
          # e.g. +json_object('category', NEW."category")+. An empty +key_columns+ yields an empty
          # object, which widens maintenance to a full recompute (correct for an un-grouped view).
          #
          # @param json_fn [String] the dialect's JSON-object constructor
          # @param row_alias [String] "NEW" or "OLD"
          def json_object(connection, json_fn, row_alias, key_columns)
            pairs = key_columns.flat_map do |col|
              [connection.quote(col), "#{row_alias}.#{connection.quote_column_name(col)}"]
            end
            "#{json_fn}(#{pairs.join(', ')})"
          end

          # The three per-operation descriptors for a table, given its +before+/+after+ key-image
          # expressions: a create captures only +after+, a destroy only +before+, an update both.
          def ops(before, after)
            [
              Op.new(suffix: "ins", event: "INSERT", operation: "create", before: "NULL", after: after),
              Op.new(suffix: "upd", event: "UPDATE", operation: "update", before: before, after: after),
              Op.new(suffix: "del", event: "DELETE", operation: "destroy", before: before, after: "NULL")
            ]
          end

          # The +INSERT INTO outbox ... VALUES (...)+ fragment shared by every dialect's trigger body.
          # +CURRENT_TIMESTAMP+ is portable across all three adapters.
          def insert_values(connection, table, op_spec)
            outbox = connection.quote_table_name(WriteOutbox.table_name)
            <<~SQL.squish
              INSERT INTO #{outbox} (source_table, operation, key_before, key_after, created_at)
              VALUES (#{connection.quote(table)}, #{connection.quote(op_spec.operation)}, #{op_spec.before}, #{op_spec.after}, CURRENT_TIMESTAMP)
            SQL
          end
        end

        # SQLite: one trigger per operation; +json_object+; a +BEGIN ... END+ body.
        module SQLite
          module_function

          def install!(connection, table, key_columns)
            uninstall!(connection, table)
            before = SharedSql.json_object(connection, "json_object", "OLD", key_columns)
            after = SharedSql.json_object(connection, "json_object", "NEW", key_columns)
            SharedSql.ops(before, after).each { |op_spec| connection.execute(trigger(connection, table, op_spec)) }
          end

          def uninstall!(connection, table)
            base = SharedSql.trigger_base(table)
            %w[ins upd del].each do |suffix|
              connection.execute("DROP TRIGGER IF EXISTS #{connection.quote_column_name("#{base}_#{suffix}")}")
            end
          end

          def trigger(connection, table, op_spec)
            name = connection.quote_column_name("#{SharedSql.trigger_base(table)}_#{op_spec.suffix}")
            <<~SQL.squish
              CREATE TRIGGER #{name} AFTER #{op_spec.event} ON #{connection.quote_table_name(table)}
              BEGIN #{SharedSql.insert_values(connection, table, op_spec)}; END
            SQL
          end
        end

        # MySQL/MariaDB/trilogy: one trigger per operation; +JSON_OBJECT+; a single-statement body
        # (no BEGIN/END, so no DELIMITER handling needed).
        module MySQL
          module_function

          def install!(connection, table, key_columns)
            uninstall!(connection, table)
            before = SharedSql.json_object(connection, "JSON_OBJECT", "OLD", key_columns)
            after = SharedSql.json_object(connection, "JSON_OBJECT", "NEW", key_columns)
            SharedSql.ops(before, after).each { |op_spec| connection.execute(trigger(connection, table, op_spec)) }
          end

          def uninstall!(connection, table)
            base = SharedSql.trigger_base(table)
            %w[ins upd del].each do |suffix|
              connection.execute("DROP TRIGGER IF EXISTS #{connection.quote_column_name("#{base}_#{suffix}")}")
            end
          end

          def trigger(connection, table, op_spec)
            name = connection.quote_column_name("#{SharedSql.trigger_base(table)}_#{op_spec.suffix}")
            <<~SQL.squish
              CREATE TRIGGER #{name} AFTER #{op_spec.event} ON #{connection.quote_table_name(table)}
              FOR EACH ROW #{SharedSql.insert_values(connection, table, op_spec)}
            SQL
          end
        end

        # Postgres: a single trigger function branches on +TG_OP+ and fires for all three events.
        # +jsonb_build_object(...)::text+ so the images land in the +text+ outbox columns.
        module PostgreSQL
          module_function

          def install!(connection, table, key_columns)
            uninstall!(connection, table)
            base = SharedSql.trigger_base(table)
            before = "#{SharedSql.json_object(connection, 'jsonb_build_object', 'OLD', key_columns)}::text"
            after = "#{SharedSql.json_object(connection, 'jsonb_build_object', 'NEW', key_columns)}::text"
            connection.execute(function(connection, table, SharedSql.ops(before, after)))
            connection.execute(<<~SQL.squish)
              CREATE TRIGGER #{connection.quote_column_name(base)}
              AFTER INSERT OR UPDATE OR DELETE ON #{connection.quote_table_name(table)}
              FOR EACH ROW EXECUTE FUNCTION #{connection.quote_column_name("#{base}_fn")}()
            SQL
          end

          def uninstall!(connection, table)
            base = SharedSql.trigger_base(table)
            connection.execute(
              "DROP TRIGGER IF EXISTS #{connection.quote_column_name(base)} ON #{connection.quote_table_name(table)}"
            )
            connection.execute("DROP FUNCTION IF EXISTS #{connection.quote_column_name("#{base}_fn")}()")
          end

          # The dollar-quoted ($fn$) body avoids escaping the single quotes in the JSON key literals.
          # +ops+ is indexed by event: insert, then update, then destroy.
          def function(connection, table, ops)
            insert, update, destroy = ops
            <<~SQL.squish
              CREATE OR REPLACE FUNCTION #{connection.quote_column_name("#{SharedSql.trigger_base(table)}_fn")}()
              RETURNS trigger AS $fn$
              BEGIN
                IF (TG_OP = 'INSERT') THEN #{SharedSql.insert_values(connection, table, insert)};
                ELSIF (TG_OP = 'UPDATE') THEN #{SharedSql.insert_values(connection, table, update)};
                ELSE #{SharedSql.insert_values(connection, table, destroy)};
                END IF;
                RETURN NULL;
              END;
              $fn$ LANGUAGE plpgsql
            SQL
          end
        end
      end
    end
  end
end
