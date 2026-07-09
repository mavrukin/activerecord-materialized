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

  # A view fed through the ingestion API (change_source :none) rather than commit
  # callbacks. Pass immediate: true to refresh inline so assertions need no flush.
  # Its commit callbacks never maintain it, so an Item.create! stands in for an
  # out-of-band write the view does not observe.
  def externally_fed_view(table_name, immediate: false)
    define_view(table_name, :item_count_by_category) do
      change_source :none
      depends_on :items
      refresh_on_change(:immediate) if immediate
    end
  end

  # Record a committed write to the items table the way a dependency callback
  # would: create the row, then hand the change to the view for maintenance.
  def record_write(view_class, category, amount)
    item = Item.create!(category: category, amount: amount)
    view_class.record_write_change!(write_change(item, :create))
    item
  end

  # Capture every ActiveSupport::Notifications event under `name` fired during
  # the block, as an array of ActiveSupport::Notifications::Event.
  def capture_events(name, &block)
    events = []
    callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }
    ActiveSupport::Notifications.subscribed(callback, name, &block)
    events
  end
end
