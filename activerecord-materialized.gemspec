# frozen_string_literal: true

require_relative "lib/activerecord/materialized/version"

# Ship only what a consumer needs at runtime: the library and the
# top-level docs. Everything else (specs, benchmarks, dev tooling,
# CI config) stays in the repository and out of the package.
PACKAGED_DOCS = %w[README.md LICENSE CHANGELOG.md].freeze

packaged_file = lambda do |path|
  path.start_with?("lib/") || PACKAGED_DOCS.include?(path)
end

GEM_FILES = Dir.chdir(__dir__) do
  tracked = `git ls-files -z 2>/dev/null`.split("\x0")
  tracked = Dir["lib/**/*", *PACKAGED_DOCS] if tracked.empty?
  tracked.select { |path| packaged_file.call(path) && File.file?(path) }.sort
end

Gem::Specification.new do |spec|
  spec.name = "activerecord-materialized"
  spec.version = ActiveRecord::Materialized::VERSION
  spec.authors = ["Michael Avrukin"]
  spec.email = ["michael@avrukin.com"]

  spec.summary = "Application-level materialized views for ActiveRecord"
  spec.description = <<~DESC
    Provides transparent materialized view semantics for Rails applications
    on databases that do not support native materialized views. Precomputes
    expensive analytical queries into cache tables with scheduled or on-demand refresh.
  DESC
  spec.homepage = "https://github.com/mavrukin/activerecord-materialized"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/activerecord-materialized"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = GEM_FILES

  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "activesupport", ">= 8.0"
  spec.add_dependency "railties", ">= 8.0"
end
