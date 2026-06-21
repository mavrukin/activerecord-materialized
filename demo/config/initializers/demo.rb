# frozen_string_literal: true

# Load the JOB benchmark models, source relations, and materialized-view
# classes that this demo compares, straight from the gem repository, then the
# demo's own scenario registry.
benchmark_root = Rails.root.join("..", "benchmark")
require benchmark_root.join("support", "benchmark_connection.rb").to_s
require BenchmarkSupport::BENCHMARK_ROOT.join("support", "source_relations.rb").to_s
BenchmarkSupport.load_materialized_models!

require Rails.root.join("lib", "demo_comparison.rb").to_s

# Keep the comparison deterministic: a dependency write only marks the view
# dirty, so a human drives the refresh and can watch the view go stale and then
# catch back up. Production apps usually keep the default :async strategy that
# refreshes automatically in the background.
DemoComparison::SCENARIOS.each { |scenario| scenario.view_class.refresh_on_change(:manual) }
