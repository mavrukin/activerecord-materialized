# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized do
  subject(:gemspec) do
    Gem::Specification.load(File.expand_path("../../activerecord-materialized.gemspec", __dir__))
  end

  let(:allowed_docs) { %w[README.md LICENSE CHANGELOG.md] }

  it "packages only library code and top-level docs" do
    stray = gemspec.files.reject { |file| file.start_with?("lib/") || allowed_docs.include?(file) }

    expect(stray).to be_empty
  end

  it "includes the entry point and generator templates that ship at runtime" do
    template = "lib/generators/activerecord_materialized/install/templates/" \
               "create_ar_materialized_view_metadata.rb.erb"

    expect(gemspec.files).to include("lib/activerecord/materialized.rb", template)
  end

  it "excludes development and test artifacts from the package" do
    expect(gemspec.files).not_to include(
      a_string_starting_with("spec/"),
      a_string_starting_with("benchmark/"),
      a_string_starting_with("sorbet/"),
      "CLAUDE.md"
    )
  end

  it "declares release-quality metadata" do
    expect(gemspec.metadata).to include(
      "allowed_push_host" => "https://rubygems.org",
      "rubygems_mfa_required" => "true"
    )
    expect(gemspec.metadata["changelog_uri"]).to end_with("/CHANGELOG.md")
  end

  it "is MIT licensed and targets a supported Ruby" do
    expect(gemspec.licenses).to eq(["MIT"])
    expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("3.4.0"))).to be(true)
  end
end
