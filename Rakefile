# frozen_string_literal: true

require "bundler/setup"
require "activerecord/materialized"

Bundler::GemHelper.install_tasks

desc "Run benchmark comparing raw vs materialized queries"
task benchmark: :environment do
  load File.expand_path("benchmark/compare.rb", __dir__)
end

desc "Run slow-query benchmark (targets 1-10s raw queries)"
task "benchmark:slow" => :environment do
  load File.expand_path("benchmark/compare_slow.rb", __dir__)
end

desc "Verify MV reflects underlying data updates after refresh"
task "benchmark:verify_updates" => :environment do
  load File.expand_path("benchmark/verify_updates.rb", __dir__)
end

desc "Generate JOB-style SQLite database for benchmarks"
task "benchmark:setup" => :environment do
  load File.expand_path("benchmark/scripts/generate_job_database.rb", __dir__)
end
