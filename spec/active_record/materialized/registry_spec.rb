# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Registry do
  after do
    described_class.send(:reset!)
  end

  it "registers materialized view subclasses" do
    view_class = define_view("mv_registry_test", :item_id_sample)

    expect(described_class.all).to include(view_class)
    expect(described_class.find(view_class.view_key)).to eq(view_class)
  end

  it "refreshes all registered views" do
    refreshed = []
    recording = ->(klass) { klass.define_singleton_method(:refresh!) { |**_| refreshed << name } }
    recording.call(define_view("mv_refresh_all_a", :item_id_sample))
    recording.call(define_view("mv_refresh_all_b", :item_amount_sample))

    described_class.refresh_all!
    expect(refreshed.size).to eq(2)
  end
end
