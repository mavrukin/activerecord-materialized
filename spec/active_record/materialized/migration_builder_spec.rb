# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::MigrationBuilder do
  subject(:builder) { described_class.new(view_class) }

  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_orders_summary"
      materialized_from { ViewSources.sales_by_category }
    end
  end

  before do
    Item.delete_all
    Item.create!(category: "books", amount: 10)
  end

  it "names the migration after the cache table" do
    expect(builder.migration_class_name).to eq("CreateMvOrdersSummary")
  end

  it "emits a create_table migration with inferred columns and types" do
    source = builder.migration_source(migration_version: 8.0)

    expect(source).to include("class CreateMvOrdersSummary < ActiveRecord::Migration[8.0]")
    expect(source).to include("create_table :mv_orders_summary do |t|")
    expect(source).to include("t.string :category")
    expect(source).to include("t.integer :total_amount")
    expect(source).to include("t.integer :row_count")
  end

  it "produces syntactically valid Ruby" do
    source = builder.migration_source(migration_version: 8.0)

    expect { RubyVM::InstructionSequence.compile(source) }.not_to raise_error
  end
end
