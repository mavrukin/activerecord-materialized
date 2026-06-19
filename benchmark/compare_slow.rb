# frozen_string_literal: true

require_relative "support/benchmark_connection"
require_relative "support/dataset_info"
require_relative "support/sql_loader"

db_path = BenchmarkSupport.connect!
stats = BenchmarkSupport::DatasetInfo.collect(db_path: db_path)
BenchmarkSupport::DatasetInfo.ensure_slow_benchmark!(stats)

SLOW_QUERIES = [
  {
    name: "gender_pairing_stats",
    raw_sql_file: "gender_pairing_stats.sql",
    materialized: GenderPairingStatsView,
    min_raw_seconds: 1.0
  },
  {
    name: "company_movie_cross",
    raw_sql_file: "company_movie_cross.sql",
    materialized: CompanyMovieCrossView,
    min_raw_seconds: 1.0
  },
  {
    name: "person_movie_network",
    raw_sql_file: "person_movie_network.sql",
    materialized: PersonMovieNetworkView,
    min_raw_seconds: 2.0
  },
  {
    name: "cast_coappearance",
    raw_sql_file: "cast_coappearance.sql",
    materialized: CastCoappearanceView,
    min_raw_seconds: 1.0
  }
].freeze

puts "=" * 80
puts "ActiveRecord::Materialized — Slow Query Benchmark"
puts "Database: #{db_path}"
puts "Target: raw queries in the 1-10 second range"
puts "=" * 80
BenchmarkSupport::DatasetInfo.print_report(stats)

# Warm SQLite's page cache so timings reflect steady-state query cost, not cold start.
ActiveRecord::Base.connection.disconnect!
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path)
BenchmarkSupport.load_materialized_models!

iterations = Integer(ENV.fetch("BENCH_ITERATIONS", "5"))

results = SLOW_QUERIES.map do |query|
  raw_sql = BenchmarkSupport::SqlLoader.load(query[:raw_sql_file])

  print "Bootstrap refresh (one-time) #{query[:name]}..."
  refresh_result = query[:materialized].refresh!
  puts " #{refresh_result.row_count} rows in #{refresh_result.duration_ms}ms"

  # Discard first raw run (cache warmup), average the rest.
  warmup, = BenchmarkSupport.timed(iterations: 1) { ActiveRecord::Base.connection.select_all(raw_sql).to_a }
  raw_avg, raw_result = BenchmarkSupport.timed(iterations: iterations) { ActiveRecord::Base.connection.select_all(raw_sql).to_a }
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
printf("%-28s %12s %12s %10s %8s %6s\n", "Query", "Raw (s)", "MV read (s)", "Bootstrap(ms)", "Speedup", "Check")
puts "-" * 80
results.each do |row|
  printf(
    "%-28s %12.4f %12.4f %10d %8.1fx %6s\n",
    row[:name],
    row[:raw_avg],
    row[:mv_avg],
    row[:refresh_ms],
    row[:speedup],
    row[:flag]
  )
end

slow_count = results.count { |r| r[:raw_avg] >= 1.0 }
puts
puts "#{slow_count}/#{results.size} queries exceeded 1 second raw execution time."
puts "For write → incremental maintenance → updated read timing, run: rake benchmark:verify_updates"
if slow_count < results.size
  puts "If queries are still fast, regenerate with JOB_SCALE=stress and retry."
end
