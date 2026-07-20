# frozen_string_literal: true

require "open3"

# Decodes a dependency table's REAL change log into normalized {ActiveRecord::Materialized.ingest_change}
# descriptors — the integration-test stand-in for a log-based CDC platform (Debezium / Maxwell / Kafka
# Connect) that decodes the binlog / WAL. This is what proves the ingestion API consumes exactly what a
# real CDC consumer receives (#80): capture the change from the log, never synthesize the descriptor at
# the write site.
#
# A descriptor is +{ table:, operation:, before:, after: }+ — +operation+ mapped to the gem's
# +create/update/destroy+ (a Debezium +op+ of c/u/d/r maps the same way), and the +before+/+after+
# images keyed by column **name**, never position. Capturing the old-image partition key on an
# update/delete requires **full row images** — MySQL +binlog-row-image=FULL+ and Postgres
# +REPLICA IDENTITY FULL+ — otherwise only the primary key is logged and maintenance widens.
module CdcCapture
  module_function

  # @param kind [Symbol] the adapter's capture kind (:logical_slot, :binlog, :none)
  # @return [Strategy]
  def for(kind, table:, connection:)
    klass = { logical_slot: LogicalSlot, binlog: Binlog, none: None }.fetch(kind) do
      raise ArgumentError, "unknown CDC capture kind #{kind.inspect}"
    end
    klass.new(table: table, connection: connection)
  end

  # Lifecycle: +start+ (begin capturing) → the raw write happens → +drain+ (decoded descriptors, in
  # commit order) → +stop+ (cleanup). Subclass per engine.
  class Strategy
    def initialize(table:, connection:)
      @table = table.to_s
      @connection = connection
    end

    # Real change-log capture available for this adapter + environment?
    def capturable? = true

    # Human reason capture is unavailable (for a logged skip); nil when it is available.
    def unavailable_reason = nil

    def start; end

    # @return [Array<Hash>] decoded { table:, operation:, before:, after: } descriptors
    def drain = []

    def stop; end

    private

    # Normalize a decoded SQL literal to a Ruby value: strip a surrounding single-quoted string
    # (unescaping the doubled '' form), map an unquoted NULL to nil (mysqlbinlog emits "NULL",
    # test_decoding emits lowercase "null"), and pass bare tokens (numbers) through. A quoted 'null'
    # stays the string "null". Only the string-valued GROUP BY key must be faithful for scoping.
    def unquote(value)
      return value[1..-2].gsub("''", "'") if value.start_with?("'") && value.end_with?("'")
      return nil if %w[NULL null].include?(value)

      value
    end

    def descriptor(operation, before: nil, after: nil)
      { table: @table, operation: operation, before: before, after: after }
    end
  end

  # SQLite: embedded, with no server-side change log to decode.
  class None < Strategy
    def capturable? = false

    def unavailable_reason
      "no server change log to decode (SQLite is embedded) — exercised by the capture-shaped CdcScenario"
    end
  end

  # PostgreSQL: logical decoding through a +test_decoding+ replication slot (built in; no extension).
  # The slot must exist before the write; +REPLICA IDENTITY FULL+ makes UPDATE/DELETE log the full old
  # image (so the partition key is present, not just the PK). Changes are in the WAL at commit, so
  # +drain+ reads them synchronously — no polling, no sleep.
  class LogicalSlot < Strategy
    SLOT = "arm_cdc_capture"

    # A test_decoding change line for our table, e.g.
    #   table public.arm_line_items: INSERT: category[text]:'books' amount[integer]:10
    #   table public.arm_line_items: UPDATE: old-key: <cols> new-tuple: <cols>
    #   table public.arm_line_items: DELETE: <cols>
    # Captures the unqualified table name and the operation; BEGIN/COMMIT and other tables → no match.
    CHANGE_LINE = /\Atable\s+\S+\.(?<name>\S+):\s+(?<op>INSERT|UPDATE|DELETE):\s+(?<rest>.*)\z/

    # A "name[type]:value" column token; +value+ is a single-quoted literal (which may hold spaces and
    # doubled '' quotes) or a bare token (number/NULL/true/false).
    COLUMN = /(?<name>[^\[\s]+)\[[^\]]*\]:(?<value>'(?:[^']|'')*'|\S+)/

    # A single UPDATE-payload token: either an "old-key:"/"new-tuple:" image marker or a COLUMN. Ordered
    # so the bare markers match first; a value containing the marker text is already inside a COLUMN's
    # quoted value and never reaches the marker alternative.
    UPDATE_TOKEN = /(?<marker>old-key:|new-tuple:)|#{COLUMN.source}/

    def start
      drop_slot # clear a slot leaked by a crashed prior run
      @connection.execute("ALTER TABLE #{@connection.quote_table_name(@table)} REPLICA IDENTITY FULL")
      @connection.execute("SELECT pg_create_logical_replication_slot(#{quote(SLOT)}, 'test_decoding')")
    end

    def drain
      sql = "SELECT data FROM pg_logical_slot_get_changes(#{quote(SLOT)}, NULL, NULL)"
      @connection.select_values(sql).filter_map { |line| decode(line) }
    end

    def stop = drop_slot

    private

    def decode(line)
      match = CHANGE_LINE.match(line)
      return nil unless match && match[:name] == @table

      case match[:op]
      when "INSERT" then descriptor(:create, after: columns(match[:rest]))
      when "DELETE" then descriptor(:destroy, before: columns(match[:rest]))
      else decode_update(match[:rest])
      end
    end

    # An UPDATE payload interleaves the "old-key:"/"new-tuple:" markers with COLUMN tokens. Walking the
    # tokens (rather than string-splitting on the marker text) is robust to a value that itself contains
    # "new-tuple:", since such a value is inside quotes and is consumed as a single COLUMN token before
    # the marker alternative can match it.
    def decode_update(rest)
      before = {}
      after = {}
      target = nil
      rest.scan(UPDATE_TOKEN).each do |marker, name, value|
        if marker
          target = marker == "old-key:" ? before : after
        elsif target
          target[name] = unquote(value)
        end
      end
      descriptor(:update, before: before, after: after)
    end

    def columns(text)
      text.scan(COLUMN).to_h { |name, value| [name, unquote(value)] }
    end

    def drop_slot
      @connection.execute(
        "SELECT pg_drop_replication_slot(#{quote(SLOT)}) FROM pg_replication_slots WHERE slot_name = #{quote(SLOT)}"
      )
    end

    def quote(value) = @connection.quote(value)
  end

  # MySQL / MariaDB: decode ROW-format binlog events with +mysqlbinlog --read-from-remote-server -v+,
  # from the coordinates recorded at +start+. Requires the +mysqlbinlog+ client on PATH (gated: skips
  # when absent). +binlog-row-image=FULL+ gives complete old/new images. Reads to the current end of
  # the binlog and exits — bounded, no sleep.
  class Binlog < Strategy
    # A ROW event header + the positional-assignment line mysqlbinlog -v emits, e.g.
    #   ### UPDATE `arm_test`.`arm_line_items`   /   ###   @2='books'
    EVENT_HEADER = /\A### (?<verb>INSERT INTO|UPDATE|DELETE FROM) `[^`]+`\.`(?<name>[^`]+)`/
    ASSIGNMENT = /\A###\s+@(?<index>\d+)=(?<value>.*)\z/
    VERB_OPERATIONS = { "INSERT INTO" => :create, "UPDATE" => :update, "DELETE FROM" => :destroy }.freeze

    def capturable? = !executable.nil? && binary_logging_enabled?

    def unavailable_reason
      return "mysqlbinlog not found on PATH" if executable.nil?
      return "binary logging is not enabled on the server" unless binary_logging_enabled?

      nil
    end

    def start
      status = binlog_status
      @file = status.fetch("File")
      @position = status.fetch("Position")
    end

    def drain = parse(read_binlog).map { |descriptor| resolve(descriptor, column_names) }

    private

    # Fold mysqlbinlog's line-oriented -v output into events, then normalize each to a descriptor.
    def parse(output)
      events = []
      current = nil
      image = nil
      output.each_line { |raw| current, image = consume(raw.chomp, events, current, image) }
      events.map { |event| descriptor(event[:operation], before: event[:before], after: event[:after]) }
    end

    # Advance the (current event, fill target) state for one line: a header starts a new event (or
    # clears it, for another table), "### WHERE"/"### SET" pick the before/after image, and a
    # "###   @N=value" line fills the current target (positional @N → column name by ordinal).
    def consume(line, events, current, image)
      if (header = EVENT_HEADER.match(line))
        [begin_event(events, header), nil]
      elsif line == "### WHERE"
        [current, :before]
      elsif line == "### SET"
        [current, :after]
      else
        fill(current, image, line)
        [current, image]
      end
    end

    def begin_event(events, header)
      return nil unless header[:name] == @table

      event = { operation: VERB_OPERATIONS.fetch(header[:verb]) }
      events << event
      event
    end

    # Keep parsing pure: fill by the positional "@N" key. Mapping @N to a real column name (which needs
    # the connection) happens in a separate resolve pass, so the state machine is unit-testable.
    def fill(current, image, line)
      return unless current && image && (assign = ASSIGNMENT.match(line))

      (current[image] ||= {})["@#{assign[:index]}"] = unquote(assign[:value])
    end

    # @@log_bin is 1 when the server writes a binary log — version-independent (unlike SHOW … STATUS),
    # so it is a safe capturable? gate even on servers where binary logging is off.
    def binary_logging_enabled?
      @connection.select_value("SELECT @@log_bin").to_i == 1
    rescue ActiveRecord::StatementInvalid
      false
    end

    # Current binlog coordinates: SHOW BINARY LOG STATUS (MySQL 8.4+) with a fallback to
    # SHOW MASTER STATUS (MySQL 8.0 / MariaDB, where the newer name doesn't exist).
    def binlog_status
      @connection.select_one("SHOW BINARY LOG STATUS")
    rescue ActiveRecord::StatementInvalid
      @connection.select_one("SHOW MASTER STATUS")
    end

    def read_binlog
      out, status = Open3.capture2(
        { "MYSQL_PWD" => config[:password].to_s },
        executable, "--read-from-remote-server",
        "--host=#{config[:host]}", "--port=#{config[:port] || 3306}", "--user=#{config[:username]}",
        "--verbose", "--start-position=#{@position}", @file
      )
      raise "mysqlbinlog exited #{status.exitstatus}" unless status.success?

      out
    end

    # Rename the positional @N image keys to real column names (mysqlbinlog -v is positional; the
    # ordinal → name map comes from information_schema).
    def resolve(descriptor, columns)
      descriptor.merge(before: rename(descriptor[:before], columns), after: rename(descriptor[:after], columns))
    end

    def rename(image, columns)
      return nil if image.nil?

      image.transform_keys { |key| columns[key.delete_prefix("@").to_i - 1] }
    end

    def column_names
      @column_names ||= @connection.select_values(<<~SQL.squish)
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = #{@connection.quote(config[:database])} AND table_name = #{@connection.quote(@table)}
        ORDER BY ordinal_position
      SQL
    end

    def config = @config ||= @connection.pool.db_config.configuration_hash

    def executable
      return @executable if defined?(@executable)

      @executable = ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
                               .map { |dir| File.join(dir, "mysqlbinlog") }.find { |path| File.executable?(path) }
    end
  end
end
