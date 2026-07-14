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
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.75", require: false
  gem "rubocop-performance", "~> 1.25", require: false
  gem "rubocop-rails", "~> 2.31", require: false
  gem "rubocop-rspec", "~> 3.5", require: false
  gem "rubocop-sorbet", "~> 0.10", require: false
  gem "redcarpet", "~> 3.6", require: false
  gem "sorbet", "~> 0.5", require: false
  gem "sqlite3", "~> 2.1"
  gem "tapioca", "~> 0.16", require: false
  gem "yard", "~> 0.9", require: false
  gem "yard-sorbet", "~> 0.9"
end

# Real-database adapters for the integration matrix (spec/integration, #70).
# Excluded from the default bundle so the fast suite and contributors without
# client libraries never compile native extensions:
#   bundle config set --local without integration
# The integration workflows and `rake integration` install this group.
group :integration do
  gem "pg", "~> 1.5"
  gem "trilogy", "~> 2.8"
end
