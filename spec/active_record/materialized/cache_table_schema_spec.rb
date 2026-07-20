# frozen_string_literal: true

require "spec_helper"

# #82 — cache-column types are inferred from the projection (group-key source
# columns + aggregate function), deterministically and without depending on a
# sample row, so they are correct on an empty source and consistent across DB
# engines (the one-row probe typed everything :string when the source was empty).
RSpec.describe ActiveRecord::Materialized::CacheTableSchema do
  it "infers column types from the projection even when the source is empty" do
    Item.delete_all # empty source: the old one-row probe types every column :string
    relation = ViewSources.sales_by_category # category + SUM(amount) AS total_amount + COUNT(id) AS row_count
    types = described_class.column_definitions(ActiveRecord::Base.connection, relation).to_h { |d| [d.name, d.type] }

    expect(types["category"]).to eq(:string)      # group key -> source column type
    expect(types["total_amount"]).to eq(:decimal) # SUM widens to DECIMAL (MySQL returns SUM(int) as DECIMAL)
    expect(types["row_count"]).to eq(:integer)    # COUNT
  end

  it "resolves a bare-Symbol group key to its real column type, not :string" do
    # idiomatic AR groups/selects by Symbol; only Arel-attribute projections were
    # resolved before, so a Symbol degraded to :string and broke the build on Postgres
    relation = ViewSources.count_by_amount # group(:amount).select(:amount, COUNT(id) AS tally)
    types = described_class.column_definitions(ActiveRecord::Base.connection, relation).to_h { |d| [d.name, d.type] }

    expect(types["amount"]).to eq(:integer) # the bare Symbol's real (integer) column type
    expect(types["tally"]).to eq(:integer)  # COUNT
  end

  it "types a float SUM as :float and clamps a high-scale AVG to a valid decimal" do
    connection = ActiveRecord::Base.connection
    connection.create_table(:arm_type_probe, force: true) do |t|
      t.float :ratio                                # a float SUM must stay :float, not truncate to DECIMAL(38,0)
      t.decimal :precise, precision: 38, scale: 28  # AVG's +4 headroom would exceed MySQL's max scale of 30
    end
    probe = Class.new(ActiveRecord::Base) { self.table_name = "arm_type_probe" }
    arel = probe.arel_table
    relation = probe.select(arel[:ratio].sum.as("ratio_sum"), arel[:precise].average.as("precise_avg"))
    columns = described_class.column_definitions(connection, relation).index_by(&:name)

    # a float source stays :float, not a scale-0 decimal that would truncate the sum
    expect(columns["ratio_sum"].type).to eq(:float)
    # AVG scale = source 28 + 4 headroom, clamped to MySQL's max of 30
    expect([columns["precise_avg"].type, columns["precise_avg"].scale]).to eq([:decimal, 30])
  ensure
    connection.drop_table(:arm_type_probe, if_exists: true)
  end

  it "resolves implicit SELECT-* columns (nil projection nodes) to their real base types" do
    connection = ActiveRecord::Base.connection
    connection.create_table(:arm_star_probe, id: false, force: true) do |t|
      t.integer :hits
      t.decimal :amount, precision: 12, scale: 2
    end
    probe = Class.new(ActiveRecord::Base) { self.table_name = "arm_star_probe" }
    # a non-aggregate SELECT-* source: select_values is empty, so every projected node is nil
    types = described_class.column_definitions(connection, probe.all).index_by(&:name).transform_values(&:type)

    expect(types["hits"]).to eq(:integer) # nil node resolved by name, not degraded to :string
    expect(types["amount"]).to eq(:decimal)
  ensure
    connection.drop_table(:arm_star_probe, if_exists: true)
  end

  # #89 — a projection over an ALIASED Arel table (e.g. a self-join alias) must type against the
  # underlying real table, not fail to resolve the alias (which fell back to :string / a scale-0 wide
  # decimal / the decimal MIN/MAX fallback).
  it "types an aliased-table projection from the underlying column, across projection kinds" do
    connection = ActiveRecord::Base.connection
    probe = alias_probe(connection)
    aliased = probe.arel_table.alias("p2") # the aliased table whose name is not a real relation
    relation = probe.from(aliased).group(aliased[:qty]).select(
      aliased[:qty].as("qty"), aliased[:amount].sum.as("amount_sum"), aliased[:happened_on].maximum.as("last_on")
    )
    columns = described_class.column_definitions(connection, relation).index_by(&:name)

    # plain projection → :integer (not :string); MAX → the source date (not a decimal fallback)
    expect(columns.transform_values(&:type)).to include("qty" => :integer, "last_on" => :date)
    # SUM keeps the source column's scale (2), not the scale-0 wide-decimal fallback
    expect([columns["amount_sum"].type, columns["amount_sum"].scale]).to eq([:decimal, 2])
  ensure
    connection.drop_table(:arm_alias_probe, if_exists: true)
  end

  # A probe table with integer/decimal/date columns for the aliased-projection inference test.
  def alias_probe(connection)
    connection.create_table(:arm_alias_probe, force: true) do |t|
      t.integer :qty
      t.decimal :amount, precision: 10, scale: 2
      t.date :happened_on
    end
    Class.new(ActiveRecord::Base) { self.table_name = "arm_alias_probe" }
  end
end
