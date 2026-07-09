# frozen_string_literal: true

require "spec_helper"

# #60 — a view's changes can come from a pluggable source. The built-in callback
# tracker is the default; it can be disabled globally or per-view so maintenance
# is driven entirely through the public ingestion API by an external adapter.
module ChangeSourceConfiguration
end

RSpec.describe ChangeSourceConfiguration, :integration do
  # default_change_source is global and not reset between examples; snapshot it.
  around do |example|
    config = ActiveRecord::Materialized.configuration
    original = config.default_change_source
    example.run
  ensure
    config.default_change_source = original
  end

  describe "disabling automatic callback installation" do
    it "installs no callbacks under a :none default yet still declares the dependency tables" do
      ActiveRecord::Materialized.configuration.default_change_source = :none
      allow(ActiveRecord::Materialized::DependencyTrackable).to receive(:subscribe).and_call_original

      view = define_view("mv_cs_disabled", :item_count_by_category) { depends_on :items }

      expect(ActiveRecord::Materialized::DependencyTrackable).not_to have_received(:subscribe)
      expect(view.dependency_tables).to include("items")
    end

    it "installs callbacks when change_source :callbacks follows depends_on under a :none default" do
      ActiveRecord::Materialized.configuration.default_change_source = :none
      allow(ActiveRecord::Materialized::DependencyTrackable).to receive(:subscribe).and_call_original

      # Opting a single view back in must work regardless of declaration order.
      define_view("mv_cs_opt_in", :item_count_by_category) do
        depends_on :items
        change_source :callbacks
      end

      expect(ActiveRecord::Materialized::DependencyTrackable).to have_received(:subscribe).with(Item)
    end
  end

  describe "rejecting an unknown change source" do
    it "raises for a typo in the DSL and in configuration rather than silently disabling maintenance" do
      expect { define_view("mv_cs_typo", :item_count_by_category) { change_source :callback } }
        .to raise_error(ArgumentError, /Unknown change source/)
      expect { ActiveRecord::Materialized.configuration.default_change_source = :bogus }
        .to raise_error(ArgumentError, /Unknown change source/)
    end
  end

  describe "routing each write to a single source" do
    it "routes a committed write only to the callbacks-driven view" do
      ActiveRecord::Materialized::AsyncRefresher.paused = true
      callbacks_view = define_view("mv_cs_callbacks", :item_count_by_category) { depends_on :items }
      external_view = externally_fed_view("mv_cs_external")
      [callbacks_view, external_view].each { |v| v.rebuild!(confirm: true) }

      Item.create!(category: "books", amount: 5)

      expect(callbacks_view.dirty?).to be(true)  # maintained via the callback source
      expect(external_view.dirty?).to be(false)  # fed elsewhere, not double-maintained
    end

    it "routes an ingestion-API publish only to externally-fed views" do
      ActiveRecord::Materialized::AsyncRefresher.paused = true
      callbacks_view = define_view("mv_cs_cb_route", :item_count_by_category) { depends_on :items }
      external_view = externally_fed_view("mv_cs_ext_route")
      [callbacks_view, external_view].each { |v| v.rebuild!(confirm: true) }

      ActiveRecord::Materialized.publish_write_change!(write_change(Item.new(category: "books", amount: 5), :create))

      expect(external_view.dirty?).to be(true)   # the externally-fed view receives it
      expect(callbacks_view.dirty?).to be(false) # its own callback source owns it
    end
  end

  describe "driving maintenance through the public ingestion API" do
    it "keeps a callback-free view correct when driven only by publish_write_change!" do
      view = externally_fed_view("mv_cs_api", immediate: true)
      Item.create!(category: "books", amount: 1) # callback filtered out (view is :none)
      view.rebuild!(confirm: true)

      # A write the callback source ignores does not maintain the view...
      second = Item.create!(category: "books", amount: 2)
      expect(view.where(category: "books").pick(:item_count)).to eq(1)

      # ...until an external adapter feeds it through the public API.
      ActiveRecord::Materialized.publish_write_change!(write_change(second, :create))
      expect(view.where(category: "books").pick(:item_count)).to eq(2)
    end

    it "converges under duplicate delivery to an externally-fed view (idempotent recompute)" do
      view = externally_fed_view("mv_cs_idem", immediate: true)
      book = Item.create!(category: "books", amount: 1) # callback filtered out (view is :none)
      view.rebuild!(confirm: true)

      2.times { ActiveRecord::Materialized.publish_write_change!(write_change(book, :create)) } # at-least-once

      expect(view.where(category: "books").pick(:item_count)).to eq(1) # not 2 or 3
    end

    it "recomputes an externally-fed view via mark_dirty_for_tables!" do
      view = externally_fed_view("mv_cs_mark_dirty", immediate: true)
      Item.create!(category: "books", amount: 1) # callback filtered out (view is :none)
      view.rebuild!(confirm: true)

      Item.create!(category: "books", amount: 2) # the external feed has not reported this yet
      expect(view.where(category: "books").pick(:item_count)).to eq(1) # cache still stale

      ActiveRecord::Materialized.mark_dirty_for_tables!(["items"])
      expect(view.where(category: "books").pick(:item_count)).to eq(2) # recomputed
    end
  end
end
