# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Metadata do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_metadata_test"
      materialized_from { ViewSources.item_id_sample }
    end
  end

  let(:metadata) { described_class.new(view_class) }

  it "marks failed refreshes" do
    metadata.mark_refreshing!
    metadata.mark_failed!(StandardError.new("boom"))

    expect(metadata.refreshing?).to be(false)
    expect(metadata.record.last_error).to eq("boom")
  end
end
