# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::MaintenanceDelta do
  describe "#merge" do
    it "widens scoped deltas to full partition when a write requires it" do
      scoped = described_class.scoped([["books"]])
      full = described_class.full_partition

      expect(scoped.merge(full)).to eq(full)
    end

    it "combines partition keys from scoped writes" do
      first = described_class.scoped([["books"]])
      second = described_class.scoped([["games"]])

      expect(first.merge(second).key_tuples).to eq([["books"], ["games"]])
    end
  end
end
