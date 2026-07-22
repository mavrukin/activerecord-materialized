# frozen_string_literal: true

require "spec_helper"
require "erb"

RSpec.describe ActiveRecord::Materialized::MigrationBuilder do
  subject(:builder) { described_class.new(view_class) }

  let(:view_class) { define_view("mv_orders_summary", :sales_by_category) }

  let(:template_path) do
    File.expand_path(
      "../../../lib/generators/activerecord_materialized/templates/materialized_view_migration.rb.erb",
      __dir__
    )
  end

  let(:rendered_migration) { ERB.new(File.read(template_path), trim_mode: "-").result(binding) }

  before { seed_items(["books", 10]) }

  it "names the migration after the cache table" do
    expect(builder.migration_class_name).to eq("CreateMvOrdersSummary")
  end

  it "infers column names and types from the source relation" do
    types_by_name = builder.column_definitions.to_h { |column| [column.name, column.type] }

    expect(types_by_name).to include("category" => :string, "total_amount" => :decimal, "row_count" => :integer)
  end

  it "renders a valid create_table migration through the generator template" do
    # structure + every inferred column; SUM widens to decimal, with precision/scale rendered
    expect(rendered_migration).to include("class CreateMvOrdersSummary < ActiveRecord::Migration[")
      .and include("create_table :mv_orders_summary do |t|")
      .and include("t.string :category")
      .and include("t.decimal :total_amount, precision: 38, scale: 0")
      .and include("t.integer :row_count")
      .and include("t.index [:category], unique: true") # #127 partition-key index
    expect { RubyVM::InstructionSequence.compile(rendered_migration) }.not_to raise_error
  end

  it "exposes the partition-key index (GROUP BY key, unique) for the generator" do
    expect([builder.index_definition.columns, builder.index_definition.unique]).to eq([["category"], true])
  end
end
