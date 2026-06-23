# frozen_string_literal: true

require "spec_helper"

# A view whose GROUP BY key (authors.country) lives on a JOINED table, not the
# base table the source relation is built from (books). Exercises partition
# scoping, scoped maintenance, and warm-up for that shape (issue #47).
class Author < ActiveRecord::Base
end

class Book < ActiveRecord::Base
  belongs_to :author
end

module JoinedKeyPartition
end

RSpec.describe JoinedKeyPartition, :integration do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      extend ActiveRecord::Materialized::QueryExpressions

      self.table_name = "mv_pages_by_country"

      materialized_from do
        authors = Author.arel_table
        Book.joins(:author).group(authors[:country]).select(
          authors[:country],
          sum_as(Book.arel_table[:pages], as: :total_pages),
          count_all_as(as: :book_count)
        )
      end

      depends_on Book, Author
      refresh_on_change :manual
    end
  end

  before do
    connection = ActiveRecord::Base.connection
    connection.create_table :authors, force: true do |t|
      t.string :country, null: false
    end
    connection.create_table :books, force: true do |t|
      t.references :author, null: false
      t.integer :pages, null: false
    end

    us = Author.create!(country: "US")
    uk = Author.create!(country: "UK")
    Book.create!(author: us, pages: 100)
    Book.create!(author: us, pages: 200)
    Book.create!(author: uk, pages: 50)
  end

  it "scopes a single partition to the joined column without raising" do
    relation = view_class.view_definition.partition_scope([["US"]])

    expect { relation.to_a }.not_to raise_error
    expect(relation.to_sql).to include('"authors"."country"')
    expect(relation.map { |row| row.attributes["country"] }).to eq(["US"])
  end

  it "maintains only the affected partition in place after a write" do
    view_class.rebuild!(confirm: true)
    expect(view_class.order(:country).pluck(:country, :total_pages)).to eq([["UK", 50], ["US", 300]])

    Book.create!(author: Author.find_by(country: "US"), pages: 25)
    ActiveRecord::Materialized::MaintenanceStore.new(view_class).merge!(
      ActiveRecord::Materialized::MaintenanceDelta.scoped([["US"]])
    )
    view_class.refresh!

    expect(view_class.find_by(country: "US").total_pages).to eq(325)
    expect(view_class.find_by(country: "UK").total_pages).to eq(50) # untouched
  end

  it "warms a single joined-key partition ahead of traffic" do
    view_class.warm_up { [where(country: "US")] }

    view_class.warm_up!

    partitions = ActiveRecord::Materialized::PartitionState.new(view_class)
    expect(partitions.all_fresh?([["US"]])).to be(true)
    expect(partitions.all_fresh?([["UK"]])).to be(false)
    expect(view_class.where(country: "US").pick(:total_pages)).to eq(300)
  end
end
