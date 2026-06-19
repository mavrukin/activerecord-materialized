# frozen_string_literal: true

require_relative "lib/activerecord/materialized/version"

def gem_files
  reject_sqlite = lambda do |file|
    file.start_with?("benchmark/fixtures/job.sqlite") || file.end_with?(".sqlite")
  end

  fallback = lambda do
    Dir["{lib,spec,benchmark}/**/*", "LICENSE", "README.md", "CHANGELOG.md", "Rakefile", "Gemfile"]
      .reject(&reject_sqlite)
  end

  Dir.chdir(__dir__) do
    next fallback.call unless File.directory?(".git")

    files = `git ls-files -z 2>/dev/null`.split("\x0").reject(&reject_sqlite)
    files.empty? ? fallback.call : files
  end
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

  spec.files = gem_files

  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "activesupport", ">= 8.0"
  spec.add_dependency "railties", ">= 8.0"
  spec.add_dependency "sorbet-runtime", ">= 0.5"

  spec.add_development_dependency "benchmark", ">= 0.4"
  spec.add_development_dependency "benchmark-ips", "~> 2.13"
  spec.add_development_dependency "lefthook", "~> 1.10"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.75"
  spec.add_development_dependency "rubocop-performance", "~> 1.25"
  spec.add_development_dependency "rubocop-rails", "~> 2.31"
  spec.add_development_dependency "rubocop-rspec", "~> 3.5"
  spec.add_development_dependency "rubocop-sorbet", "~> 0.10"
  spec.add_development_dependency "sorbet", "~> 0.5"
  spec.add_development_dependency "sqlite3", "~> 2.1"
  spec.add_development_dependency "tapioca", "~> 0.16"
end
