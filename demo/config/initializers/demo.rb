# frozen_string_literal: true

# Load the JOB benchmark models, source relations, and materialized-view
# classes that this demo compares, straight from the gem repository, then the
# demo's own scenario registry.
benchmark_root = Rails.root.join("..", "benchmark")
require benchmark_root.join("support", "benchmark_connection.rb").to_s
require BenchmarkSupport::BENCHMARK_ROOT.join("support", "source_relations.rb").to_s
BenchmarkSupport.load_materialized_models!

require Rails.root.join("lib", "demo_comparison.rb").to_s

# Demonstrate the real refresh-on-write behaviour: a dependency write marks the
# view stale and an in-process background refresh brings it back up to date on
# its own (the gem's default :async strategy). A short debounce keeps the demo
# snappy; the page polls the view status so you can watch it recover.
DemoComparison::SCENARIOS.each do |scenario|
  scenario.view_class.refresh_on_change(:async)
  scenario.view_class.refresh_debounce(0.3)
end

# WAL lets reads (and the status poller) proceed while a background refresh holds
# the write lock — without it SQLite blocks every read for the refresh's duration.
DemoComparison::Database.enable_wal!
