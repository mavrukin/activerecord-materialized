# frozen_string_literal: true

require "spec_helper"

load File.expand_path("../../../bin/affected-specs", __dir__)

RSpec.describe AffectedSpecs do
  describe ".specs_for_files" do
    it "maps a lib file to its direct spec" do
      specs = described_class.specs_for_files(["lib/activerecord/materialized/metadata.rb"])
      expect(specs).to eq(["spec/active_record/materialized/metadata_spec.rb"])
    end

    it "maps view concern modules to view_spec" do
      specs = described_class.specs_for_files(["lib/activerecord/materialized/view_configuration_class_methods.rb"])
      expect(specs).to eq(["spec/active_record/materialized/view_spec.rb"])
    end

    it "runs changed spec files directly" do
      specs = described_class.specs_for_files(["spec/active_record/materialized/refresher_spec.rb"])
      expect(specs).to eq(["spec/active_record/materialized/refresher_spec.rb"])
    end

    it "skips heavy benchmark integration spec" do
      specs = described_class.specs_for_files(["spec/active_record/materialized/async_refresher_flush_spec.rb"])
      expect(specs).to eq([])
    end

    it "returns empty for non-code paths" do
      specs = described_class.specs_for_files(["benchmark/compare.rb", "README.md"])
      expect(specs).to eq([])
    end

    it "runs the fast suite when spec_helper changes" do
      specs = described_class.specs_for_files(["spec/spec_helper.rb"])
      expect(specs).not_to include("spec/active_record/materialized/async_refresher_flush_spec.rb")
      expect(specs.size).to be > 1
    end
  end
end
