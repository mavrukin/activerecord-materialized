# frozen_string_literal: true

require_relative "../../../benchmark/support/cdc_scenario"

# Schema, models, and views for the real-DB integration matrix (#70, #84), portable
# across SQLite / MySQL / Postgres via ActiveRecord schema statements. The CDC
# scenario (#70) drives line_items_by_category; the load-bearing suite (#84) adds a
# wide multi-aggregate view (line_item_metrics) and a join-keyed view (pages_by_country).
module IntegrationSchema
  extend ActiveRecord::Materialized::QueryExpressions

  # A dependency row. category groups the view; amount is summed. `sum` is
  # deliberate: its Ruby type diverges by engine (Integer on SQLite vs BigDecimal
  # on MySQL/Postgres), exactly the portability the matrix exercises.
  class LineItem < ActiveRecord::Base
    self.table_name = "arm_line_items"
  end

  class Author < ActiveRecord::Base
    self.table_name = "arm_authors"
  end

  class Book < ActiveRecord::Base
    self.table_name = "arm_books"
    belongs_to :author, class_name: "IntegrationSchema::Author"
  end

  MODELS = [LineItem, Author, Book].freeze

  module_function

  def provision!(connection = ActiveRecord::Base.connection)
    connection.create_table(:arm_line_items, force: true) do |t|
      t.string :category, null: false
      t.string :sku # nullable: the CDC scenario writes rows without it
      t.integer :amount, null: false
    end
    connection.create_table(:arm_authors, force: true) { |t| t.string :country, null: false }
    connection.create_table(:arm_books, force: true) do |t|
      t.references :author, null: false
      t.integer :pages, null: false
    end
    register_models!
  end

  # Attach the models to the current connection without recreating tables — used by a
  # spawned concurrency worker, which connects to tables the parent already provisioned.
  def register_models!
    MODELS.each(&:reset_column_information)
    MODELS.each { |model| ActiveRecord::Materialized::TableModelRegistry.register(model) }
  end

  # #70 CDC-scenario view: exact count + sum by category (COUNT integer, SUM decimal).
  def define_view(table_name)
    build_view(table_name, :arm_line_items, source: -> { IntegrationSchema.line_items_by_category })
  end

  def line_items_by_category
    items = LineItem.arel_table
    LineItem.group(:category).select(
      items[:category], count_all_as(as: :item_count), sum_as(items[:amount], as: :total_amount)
    )
  end

  # #84 wide view: every aggregate shape, surfacing cross-engine type inference (#82).
  def define_metrics_view(table_name)
    build_view(table_name, :arm_line_items, source: -> { IntegrationSchema.line_item_metrics })
  end

  def line_item_metrics
    items = LineItem.arel_table
    LineItem.group(:category).select(
      items[:category],
      count_all_as(as: :item_count),
      sum_as(items[:amount], as: :total_amount),
      avg_as(items[:amount], as: :avg_amount),
      min_as(items[:amount], as: :min_amount),
      max_as(items[:amount], as: :max_amount),
      count_distinct_as(items[:sku], as: :sku_count)
    )
  end

  # #84 concurrency view: callback-fed, scoped-recompute (MAX is non-distributive, so
  # the view can't take the additive summary-delta path), integer-exact — converges
  # under concurrent cross-process maintenance.
  def define_scoped_view(table_name, &config)
    build_view(
      table_name, :arm_line_items,
      changes: :callbacks, source: -> { IntegrationSchema.line_item_scoped_metrics }, &config
    )
  end

  def line_item_scoped_metrics
    items = LineItem.arel_table
    LineItem.group(:category).select(
      items[:category], count_all_as(as: :item_count), max_as(items[:amount], as: :max_amount)
    )
  end

  # #75 summary-delta view: COUNT + SUM (distributive aggregates plus a row count), callback-fed
  # and manually refreshed, so writes accumulate an additive delta that concurrent refreshers race
  # to consume — exercising the non-idempotent summary-delta path under the real cross-process lock.
  def define_delta_view(table_name)
    build_view(
      table_name, :arm_line_items,
      changes: :callbacks, source: -> { IntegrationSchema.line_items_by_category }
    ) { refresh_on_change :manual }
  end

  # #84 join-keyed view: grouped by the JOINED authors.country, scoped-recompute
  # maintained, with a partition_key_for resolver for leaf-table (books) writes.
  def define_pages_by_country_view(table_name)
    build_view(table_name, :arm_books, :arm_authors, source: -> { IntegrationSchema.pages_by_country }) do
      partition_key_for(:arm_books) do |change|
        ids = [change.before["author_id"], change.after["author_id"]].compact.uniq
        IntegrationSchema::Author.where(id: ids).pluck(:country)
      end
    end
  end

  def pages_by_country
    authors = Author.arel_table
    Book.joins(:author).group(authors[:country]).select(
      authors[:country], sum_as(Book.arel_table[:pages], as: :total_pages), count_all_as(as: :book_count)
    )
  end

  # Bulk-load line items across many categories/skus via a single raw INSERT — fast,
  # and (like a real bulk / out-of-band write) bypassing ActiveRecord entirely.
  def bulk_seed_line_items(count, connection = ActiveRecord::Base.connection)
    values = Array.new(count) do |i|
      "(#{connection.quote("cat-#{i % 100}")}, #{connection.quote("sku-#{i % 250}")}, #{(i % 50) + 1})"
    end
    connection.execute("INSERT INTO arm_line_items (category, sku, amount) VALUES #{values.join(', ')}")
  end

  # Build an anonymous View subclass for a cache table — anonymous per call so no
  # view-level state leaks across examples. `changes` sets the change source before
  # depends_on (CDC-relayed :none, the default here, vs callback-fed :callbacks) so a
  # :none view installs no callbacks; extra class-body DSL (e.g. partition_key_for) goes
  # in the block.
  def build_view(table_name, *dependencies, source:, changes: :none, &config)
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = table_name
      change_source changes
      depends_on(*dependencies)
      refresh_on_change :immediate
      materialized_from(&source)
      class_eval(&config) if config
    end
  end
end
