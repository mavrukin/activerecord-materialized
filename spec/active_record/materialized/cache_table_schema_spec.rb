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
end
