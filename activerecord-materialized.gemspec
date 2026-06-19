# frozen_string_literal: true

require_relative "lib/activerecord/materialized/version"

reject_sqlite = lambda do |file|
  file.start_with?("benchmark/fixtures/job.sqlite") || file.end_with?(".sqlite")
end

fallback_files = lambda do
  Dir["{lib,spec,benchmark}/**/*", "LICENSE", "README.md", "CHANGELOG.md", "Rakefile", "Gemfile"]
    .reject(&reject_sqlite)
end

GEM_FILES = Dir.chdir(__dir__) do
  next fallback_files.call unless File.directory?(".git")

  files = `git ls-files -z 2>/dev/null`.split("\x0").reject(&reject_sqlite)
  files.empty? ? fallback_files.call : files
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

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/mavrukin/activerecord-materialized"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = GEM_FILES

  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "activesupport", ">= 8.0"
  spec.add_dependency "railties", ">= 8.0"
  spec.add_dependency "sorbet-runtime", ">= 0.5"
end
