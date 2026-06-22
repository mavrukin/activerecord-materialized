# frozen_string_literal: true

# Shared scaffolding for view specs: building anonymous views, seeding the
# items table, and constructing write changes.
module MaterializedViewHelpers
  # An anonymous view backed by `table_name`, optionally sourced from a
  # ViewSources method, with any extra DSL supplied in the block.
  def define_view(table_name, source = nil, &config)
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = table_name
      materialized_from { ViewSources.public_send(source) } if source
      class_eval(&config) if config
    end
  end

  # Seed the items table from [category, amount] pairs.
  def seed_items(*rows)
    Item.delete_all
    rows.map { |category, amount| Item.create!(category: category, amount: amount) }
  end

  def write_change(record, operation)
    ActiveRecord::Materialized::WriteChange.from_record(record, operation)
  end
end
