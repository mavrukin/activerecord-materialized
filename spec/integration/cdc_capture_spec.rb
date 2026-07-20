# frozen_string_literal: true

require "spec_helper"
require_relative "support/cdc_capture"

# Unit coverage for the CDC change-log decoders (#80) — pure text parsing, no database, so it runs in
# the fast gate (like integration_adapters_spec). Exercises the edge cases the real-DB matrix can't
# easily hit with its safe fixture values: NULL rendering, quoted values containing the structural
# marker, and other-table filtering.
RSpec.describe CdcCapture do
  describe CdcCapture::LogicalSlot do # Postgres test_decoding text — parsed without a connection
    subject(:strategy) { described_class.new(table: "arm_line_items", connection: nil) }

    def decode(line) = strategy.send(:decode, line)

    # Decode an arm_line_items change; the "table public.<t>: " prefix is implied to keep lines short.
    def change(operation_and_columns) = decode("table public.arm_line_items: #{operation_and_columns}")

    it "decodes INSERT/UPDATE/DELETE lines into scoped before/after descriptors" do
      insert = change("INSERT: category[text]:'books' amount[integer]:10")
      update = change("UPDATE: old-key: category[text]:'books' new-tuple: category[text]:'games'")
      delete = change("DELETE: category[text]:'games' amount[integer]:10")

      expect(insert).to include(operation: :create, after: include("category" => "books"))
      expect(update).to include(operation: :update, before: include("category" => "books"),
                                after: include("category" => "games"))
      expect(delete).to include(operation: :destroy, before: include("category" => "games"))
    end

    it "ignores transaction framing and other tables" do
      expect(decode("BEGIN 42")).to be_nil
      expect(decode("table public.other_table: INSERT: id[integer]:1")).to be_nil
    end

    it "maps an unquoted null to nil but keeps a quoted value (spaces, doubled quotes, literal 'null')" do
      row = change("INSERT: category[text]:'a b' sku[text]:null note[text]:'it''s ''null'''")

      expect(row[:after]).to eq("category" => "a b", "sku" => nil, "note" => "it's 'null'")
    end

    it "keeps the old/new boundary when a value contains the new-tuple marker text" do
      row = change("UPDATE: old-key: category[text]:'x new-tuple: y' new-tuple: category[text]:'z'")

      expect(row[:before]).to eq("category" => "x new-tuple: y")
      expect(row[:after]).to eq("category" => "z")
    end
  end

  describe CdcCapture::Binlog do # mysqlbinlog -v ROW output — pure parse (positional @N keys, no DB)
    subject(:strategy) { described_class.new(table: "arm_line_items", connection: nil) }

    def parse(output) = strategy.send(:parse, output)

    it "folds ### ROW events into descriptors by positional @N, skipping other tables" do
      descriptors = parse(<<~BINLOG)
        ### INSERT INTO `db`.`arm_line_items`
        ### SET
        ###   @1=1
        ###   @2='books'
        ###   @3=NULL
        ### UPDATE `db`.`arm_line_items`
        ### WHERE
        ###   @2='books'
        ### SET
        ###   @2='games'
        ### DELETE FROM `db`.`other_table`
        ### WHERE
        ###   @1=9
      BINLOG

      # A create fills only the after-image (SET); a bare NULL maps to nil; the other-table event drops.
      # Keys stay positional (@N) — resolve() renames them to real columns at drain time.
      expect(descriptors).to eq([
                                  { table: "arm_line_items", operation: :create, before: nil,
                                    after: { "@1" => "1", "@2" => "books", "@3" => nil } },
                                  { table: "arm_line_items", operation: :update,
                                    before: { "@2" => "books" }, after: { "@2" => "games" } }
                                ])
    end

    it "renames positional keys to real columns by ordinal" do
      descriptor = { operation: :create, before: nil, after: { "@1" => "1", "@2" => "books" } }

      resolved = strategy.send(:resolve, descriptor, %w[id category amount])

      expect(resolved[:after]).to eq("id" => "1", "category" => "books")
    end
  end
end
