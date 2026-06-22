# frozen_string_literal: true

require_relative "support/benchmark_connection"
require_relative "support/dataset_info"
require_relative "support/table_formatter"

db_path = BenchmarkSupport.connect!
stats = BenchmarkSupport::DatasetInfo.collect(db_path: db_path)
BenchmarkSupport::DatasetInfo.ensure_slow_benchmark!(stats)

SLOW_QUERIES = [
  { name: "gender_pairing_stats", materialized: GenderPairingStatsView, min_raw_seconds: 1.0 },
  { name: "company_movie_cross", materialized: CompanyMovieCrossView, min_raw_seconds: 1.0 },
  { name: "person_movie_network", materialized: PersonMovieNetworkView, min_raw_seconds: 2.0 },
  { name: "cast_coappearance", materialized: CastCoappearanceView, min_raw_seconds: 1.0 }
].freeze

puts "=" * 80
puts "ActiveRecord::Materialized — Slow Query Benchmark"
puts "Database: #{db_path}"
puts "Target: raw queries in the 1-10 second range"
puts "=" * 80
BenchmarkSupport::DatasetInfo.print_report(stats)

ActiveRecord::Base.connection.disconnect!
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path)
BenchmarkSupport.load_materialized_models!

iterations = Integer(ENV.fetch("BENCH_ITERATIONS", "5"))

results = SLOW_QUERIES.map do |query|
  print "Bootstrap refresh (one-time) #{query[:name]}..."
  refresh_result = query[:materialized].rebuild!(confirm: true)
  puts " #{refresh_result.row_count} rows in #{refresh_result.duration_ms}ms"

  # Build a fresh relation per iteration. An ActiveRecord::Relation memoizes its
  # rows once loaded, so reusing one object measures cached-array iteration
  # (~0ms) rather than the query — which made raw look faster than the MV (#40).
  run_raw = -> { query[:materialized].resolved_source.map(&:attributes) }
  warmup, = BenchmarkSupport.timed(iterations: 1, &run_raw)
  raw_avg, raw_result = BenchmarkSupport.timed(iterations: iterations, &run_raw)
  mv_avg, mv_result = BenchmarkSupport.timed(iterations: iterations) { query[:materialized].all.map(&:attributes) }

  flag = raw_avg >= query[:min_raw_seconds] ? "OK" : "WARN (< #{query[:min_raw_seconds]}s)"
  {
    name: query[:name],
    raw_avg: raw_avg,
    warmup: warmup,
    mv_avg: mv_avg,
    refresh_ms: refresh_result.duration_ms,
    raw_rows: raw_result.size,
    mv_rows: mv_result.size,
    speedup: mv_avg.zero? ? Float::INFINITY : raw_avg / mv_avg,
    flag: flag
  }
end

puts
BenchmarkSupport::TableFormatter.print_slow_header
puts "-" * 80
results.each do |row|
  BenchmarkSupport::TableFormatter.print_slow_row(
    query: row[:name],
    raw: row[:raw_avg],
    mv_read: row[:mv_avg],
    refresh: row[:refresh_ms],
    speedup: row[:speedup],
    check: row[:flag]
  )
end

slow_count = results.count { |r| r[:raw_avg] >= 1.0 }
puts
puts "#{slow_count}/#{results.size} queries exceeded 1 second raw execution time."
puts "For write → incremental maintenance → updated read timing, run: rake benchmark:verify_updates"
puts "If queries are still fast, regenerate with JOB_SCALE=stress and retry." if slow_count < results.size
