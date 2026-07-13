# frozen_string_literal: true

# Load the JOB benchmark models and source relations from the gem repository,
# then the demo's own scenario registry.
benchmark_root = Rails.root.join("..", "benchmark")
require benchmark_root.join("support", "benchmark_connection.rb").to_s
require BenchmarkSupport::BENCHMARK_ROOT.join("support", "source_relations.rb").to_s
# The reusable CDC scenario/validation harness the demo shares with the integration
# suite (its ResultComparison also backs the demo's raw-vs-view equality check).
require BenchmarkSupport::BENCHMARK_ROOT.join("support", "cdc_scenario.rb").to_s
BenchmarkSupport.load_job_models!

require Rails.root.join("lib", "demo_comparison.rb").to_s

# Load only the materialized views this demo actually shows. Loading the full
# benchmark set would register extra cast_info-dependent views (e.g. the heavy
# CastCoappearanceView) that would then be refreshed on every "Insert cast rows"
# even though they never appear in the UI.
DemoComparison::SCENARIOS.each do |scenario|
  require BenchmarkSupport::BENCHMARK_ROOT.join("materialized_models", "#{scenario.view_name.underscore}.rb").to_s
end

# The CDC scenario's view is fed through the ingestion API (change_source :none) and
# keeps its own :immediate policy — load it outside the callback-strategy override
# below so it stays callback-free.
require BenchmarkSupport::BENCHMARK_ROOT.join("materialized_models", "cdc_company_links_view.rb").to_s

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
