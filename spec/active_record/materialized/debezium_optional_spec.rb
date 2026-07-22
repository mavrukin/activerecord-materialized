# frozen_string_literal: true

require "spec_helper"

# #113 — Debezium is OPTIONAL convenience, never a hard requirement: the gem depends on no
# Debezium/Kafka library, Debezium is not a first-class change source, and every maintenance path
# works without touching the Debezium adapter. These are regression guards for that property — they
# would fail if a future change made Debezium a dependency, a configurable source, or a required step.
module DebeziumOptional
end

RSpec.describe DebeziumOptional, :integration do
  it "drives full maintenance through the tool-agnostic ingestion API with no Debezium involvement" do
    view = externally_fed_view("mv_no_debezium", immediate: true)
    Item.create!(category: "books", amount: 1) # unobserved by the :none view
    view.rebuild!(confirm: true)
    expect(view.where(category: "books").pick(:item_count)).to eq(1)

    # A Maxwell / Kafka-Connect / custom / raw consumer relays exactly this call — no DebeziumEnvelope,
    # no ingest_debezium_change — and the view converges.
    Item.create!(category: "books", amount: 5)
    ActiveRecord::Materialized.ingest_change(table: "items", operation: :create, after: { "category" => "books" })

    expect(view.where(category: "books").pick(:item_count)).to eq(2)
  end

  it "does not make Debezium a first-class change source" do
    # The only change sources are callbacks (default) and none; Debezium is not one — it is just a way
    # to produce descriptors for the :none path via the optional ingest_debezium_change helper.
    expect(ActiveRecord::Materialized::ChangeSource::NAMES).to contain_exactly(:callbacks, :none)
    expect(ActiveRecord::Materialized::ChangeSource::NAMES).not_to include(:debezium)
  end

  it "declares no Debezium or Kafka runtime dependency" do
    gemspec = Gem::Specification.load(File.expand_path("../../../activerecord-materialized.gemspec", __dir__))
    runtime = gemspec.runtime_dependencies.map(&:name)

    # The gem's runtime deps are only ActiveRecord/ActiveSupport/Railties — installing it pulls in no
    # Debezium/Kafka/Connect client, so Debezium can never be a hard install-time requirement.
    expect(runtime).to all(match(/\A(activerecord|activesupport|railties)\z/))
  end
end
