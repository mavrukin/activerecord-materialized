# frozen_string_literal: true

require_relative "../../../benchmark/support/cdc_scenario"

# Schema-agnostic fixtures for the real-DB integration matrix (#70): one
# dependency table, its model, and a count/sum-by-category materialized view fed
# by the CDC ingestion API (change_source :none). Portable across SQLite, MySQL,
# and Postgres via ActiveRecord schema statements — no raw DDL.
module IntegrationSchema
  extend ActiveRecord::Materialized::QueryExpressions

  # A dependency row. category groups the view; amount is summed. `sum` is
  # deliberate: its Ruby type diverges by engine (Integer on SQLite vs BigDecimal
  # on MySQL/Postgres), exactly the portability the matrix exercises.
  class LineItem < ActiveRecord::Base
    self.table_name = "arm_line_items"
  end

  module_function

  # (Re)create the dependency table on the current connection and register its
  # model, so the same view definition runs against whichever adapter is active.
  def provision!(connection = ActiveRecord::Base.connection)
    connection.create_table(:arm_line_items, force: true) do |t|
      t.string :category, null: false
      t.integer :amount, null: false
    end
    LineItem.reset_column_information
    ActiveRecord::Materialized::TableModelRegistry.register(LineItem)
  end

  # An anonymous, CDC-fed (change_source :none), immediately-refreshed view over
  # arm_line_items. Anonymous per call so no view-level state leaks across examples.
  def define_view(table_name)
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = table_name
      change_source :none
      depends_on :arm_line_items
      refresh_on_change :immediate
      materialized_from { IntegrationSchema.line_items_by_category }
    end
  end

  def line_items_by_category
    line_items = LineItem.arel_table
    LineItem.group(:category).select(
      line_items[:category],
      count_all_as(as: :item_count),
      sum_as(line_items[:amount], as: :total_amount)
    )
  end
end
