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

    expect(types_by_name).to include("category" => :string, "total_amount" => :integer, "row_count" => :integer)
  end

  it "renders a valid create_table migration through the generator template" do
    expect(rendered_migration).to include("class CreateMvOrdersSummary < ActiveRecord::Migration[")
    expect(rendered_migration).to include("create_table :mv_orders_summary do |t|")
    expect(rendered_migration).to include("t.string :category")
    expect(rendered_migration).to include("t.integer :total_amount")
    expect { RubyVM::InstructionSequence.compile(rendered_migration) }.not_to raise_error
  end
end
