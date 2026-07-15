# frozen_string_literal: true

module ViewSources
  extend ActiveRecord::Materialized::QueryExpressions

  module_function

  def sales_by_category
    items = Item.arel_table
    Item.group(:category).select(
      items[:category],
      sum_as(items[:amount], as: :total_amount),
      count_as(items[:id], as: :row_count)
    )
  end

  def sales_by_category_with_totals
    items = Item.arel_table
    Item.group(:category).select(
      items[:category],
      sum_as(items[:amount], as: :total_amount)
    )
  end

  def item_count_by_category
    items = Item.arel_table
    Item.group(:category).select(
      items[:category],
      count_as(items[:id], as: :item_count)
    )
  end

  # A group key projected as a bare Symbol over an INTEGER column — the idiomatic-AR
  # form the gem's own views avoid (they project Arel attributes). Its cache type must
  # resolve to the real column type (:integer), not degrade to :string.
  def count_by_amount
    Item.group(:amount).select(:amount, count_as(Item.arel_table[:id], as: :tally))
  end

  # A dotted GROUP BY string ("items.category") whose projected column is the bare
  # "category" — exercises qualifier-stripping when matching group keys to columns.
  def item_count_by_dotted_category
    items = Item.arel_table
    Item.group("items.category").select(
      items[:category],
      count_as(items[:id], as: :item_count)
    )
  end

  # A float-valued aggregate (AVG) — its cache column stores the value under a
  # numeric affinity that can differ in representation from the recomputed source.
  def avg_amount_by_category
    items = Item.arel_table
    Item.group(:category).select(
      items[:category],
      avg_as(items[:amount], as: :avg_amount)
    )
  end

  def revenue_by_category
    items = Item.arel_table
    amount_sum = items[:amount].sum
    Item.group(:category).select(
      items[:category],
      sum_as(items[:amount], as: :revenue),
      avg_as(items[:amount], as: :average_amount)
    ).having(amount_sum.gt(5))
  end

  def item_id_sample
    Item.select(Item.arel_table[:id]).limit(1)
  end

  def item_amount_sample
    Item.select(Item.arel_table[:amount]).limit(1)
  end

  def total_item_count
    items = Item.arel_table
    Item.select(count_as(items[:id], as: :total))
  end
end
