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
  extend ActiveRecord::Materialized::QueryExpressions

  # The source relation, grouped by the JOINED authors.country column. Extracted to
  # a method (the established pattern for large view definitions) to keep the view
  # builder simple.
  def self.pages_by_country_source
    authors = Author.arel_table
    Book.joins(:author).group(authors[:country]).select(
      authors[:country],
      sum_as(Book.arel_table[:pages], as: :total_pages),
      count_all_as(as: :book_count)
    )
  end

  # Builds the view, optionally with a partition_key_for(:books) resolver. Defined
  # here (not inside the example group) so it isn't a method defined in a block.
  def self.pages_by_country_view(table_name, &resolver)
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = table_name
      materialized_from { JoinedKeyPartition.pages_by_country_source }
      depends_on Book, Author
      refresh_on_change :manual
      partition_key_for(:books, &resolver) if resolver
    end
  end
end

RSpec.describe JoinedKeyPartition, :integration do
  let(:view_class) { described_class.pages_by_country_view("mv_pages_by_country") }

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

  # #61 — deriving the affected partition key for a write on the JOINED leaf table
  # (books), whose payload has no country column, so maintenance scopes instead of
  # widening to a full recompute.
  describe "partition_key_for resolver" do
    let(:resolving_view) do
      described_class.pages_by_country_view("mv_pages_by_country_resolved") do |change|
        author_ids = [change.before["author_id"], change.after["author_id"]].compact.uniq
        Author.where(id: author_ids).pluck(:country)
      end
    end

    it "derives the partition key for a leaf-table write and scopes maintenance to it" do
      resolving_view.rebuild!(confirm: true)
      Book.create!(author: Author.find_by(country: "US"), pages: 25) # commit callback -> resolver

      pending = ActiveRecord::Materialized::MaintenanceStore.new(resolving_view).pending
      expect(pending.full_partition?).to be(false) # scoped, not widened
      expect(pending.key_tuples).to eq([["US"]])   # to the resolved country
      resolving_view.refresh!
      expect(resolving_view.find_by(country: "US").total_pages).to eq(325)
      expect(resolving_view.find_by(country: "UK").total_pages).to eq(50) # untouched
    end

    it "scopes both partitions when a write moves a row across them" do
      resolving_view.rebuild!(confirm: true)
      Book.find_by(pages: 100).update!(author: Author.find_by(country: "UK")) # US -> UK

      pending = ActiveRecord::Materialized::MaintenanceStore.new(resolving_view).pending
      expect(pending.key_tuples).to contain_exactly(["US"], ["UK"]) # old and new
      resolving_view.refresh!
      expect(resolving_view.find_by(country: "US").total_pages).to eq(200) # 300 - 100
      expect(resolving_view.find_by(country: "UK").total_pages).to eq(150) # 50 + 100
    end

    it "widens to a full recompute when no resolver is configured" do
      view_class.rebuild!(confirm: true)
      Book.create!(author: Author.find_by(country: "US"), pages: 25)

      expect(ActiveRecord::Materialized::MaintenanceStore.new(view_class).pending.full_partition?).to be(true)
    end
  end
end
