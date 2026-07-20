# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.4.0"

gemspec

group :development, :test do
  gem "activejob", ">= 8.0"
  gem "activerecord", ">= 8.0"
  gem "activesupport", ">= 8.0"
  gem "benchmark", ">= 0.4"
  gem "benchmark-ips", "~> 2.13"
  gem "lefthook", "~> 1.10"
  gem "railties", ">= 8.0"
  gem "rake", "~> 13.0"
  gem "redcarpet", "~> 3.6", require: false
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.75", require: false
  gem "rubocop-performance", "~> 1.25", require: false
  gem "rubocop-rails", "~> 2.31", require: false
  gem "rubocop-rspec", "~> 3.5", require: false
  gem "sqlite3", "~> 2.1"
  gem "yard", "~> 0.9", require: false
end

# Real-database adapters for the integration matrix (spec/integration, #70).
# NOT installed by default (install_if is false) so the fast suite and
# contributors without client libraries never compile native extensions. Enable
# with `ARM_INTEGRATION=1 bundle install` — the integration CI workflows and
# docs/integration-testing.md do this.
install_if -> { ENV["ARM_INTEGRATION"] == "1" } do
  gem "pg", "~> 1.5"
  gem "trilogy", "~> 2.8"
end
