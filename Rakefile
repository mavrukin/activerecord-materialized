# frozen_string_literal: true

require "bundler/setup"
require "activerecord/materialized"

Bundler::GemHelper.install_tasks

# Standalone gem Rakefile — no Rails app to boot. Benchmark scripts load their own deps.
task :environment

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

desc "Simulate the full view lifecycle: cold read, build, fast read, write/maintain, warm-up"
task "benchmark:lifecycle" => :environment do
  load File.expand_path("benchmark/lifecycle.rb", __dir__)
end

desc "Generate JOB-style SQLite database for benchmarks"
task "benchmark:setup" => :environment do
  load File.expand_path("benchmark/scripts/generate_job_database.rb", __dir__)
end

desc "Run the real-DB integration matrix (honors ARM_ONLY=sqlite,mysql,postgres)"
task integration: :environment do
  sh "bundle exec rspec spec/integration --tag db_matrix"
end

namespace :integration do
  desc "Start the local MySQL/Postgres containers for the integration matrix"
  task up: :environment do
    sh "docker compose up -d --wait"
  end

  desc "Stop and remove the local integration containers"
  task down: :environment do
    sh "docker compose down -v"
  end
end
