# frozen_string_literal: true

require "spec_helper"

module MaintenanceStoreHelpers
  def summary_for(category)
    ActiveRecord::Materialized::SummaryDelta.new.tap { |delta| delta.add([category], "total_amount", 1) }
  end
end

RSpec.describe ActiveRecord::Materialized::MaintenanceStore do
  include MaintenanceStoreHelpers

  subject(:store) { described_class.new(view_class) }

  let(:view_class) { define_view("mv_store_test", :sales_by_category) }

  describe "#merge!" do
    it "accumulates distinct partitions below the cap" do
      allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(100)

      3.times { |i| store.merge!(summary_for("cat_#{i}")) }

      pending = store.pending
      expect(pending).to be_a(ActiveRecord::Materialized::SummaryDelta)
      expect(pending.tracked_partition_count).to eq(3)
    end

    it "collapses to a single full recompute once the cap is exceeded" do
      allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(3)

      6.times { |i| store.merge!(summary_for("cat_#{i}")) }

      pending = store.pending
      expect(pending).to be_a(ActiveRecord::Materialized::MaintenanceDelta)
      expect(pending.full_partition?).to be(true)
    end

    it "absorbs further writes once collapsed, keeping the payload bounded" do
      allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(2)

      10.times { |i| store.merge!(summary_for("cat_#{i}")) }
      payload_size = view_class.metadata.maintenance_payload.to_s.bytesize

      20.times { |i| store.merge!(summary_for("more_#{i}")) }

      expect(store.pending.full_partition?).to be(true)
      expect(view_class.metadata.maintenance_payload.to_s.bytesize).to eq(payload_size)
    end

    it "collapses an oversized scoped MaintenanceDelta the same way" do
      allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(3)

      6.times { |i| store.merge!(ActiveRecord::Materialized::MaintenanceDelta.scoped([["cat_#{i}"]])) }

      expect(store.pending.full_partition?).to be(true)
    end
  end
end
