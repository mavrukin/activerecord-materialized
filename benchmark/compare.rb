# frozen_string_literal: true

require_relative "support/benchmark_connection"
require_relative "support/table_formatter"

db_path = BenchmarkSupport.connect!

QUERIES = [
  { name: "gender_pairing_stats (slow)", materialized: GenderPairingStatsView },
  { name: "company_movie_cross (slow)", materialized: CompanyMovieCrossView },
  { name: "person_movie_network (slow)", materialized: PersonMovieNetworkView },
  { name: "production_notes (JOB 1a)", materialized: ProductionNotesView },
  { name: "russian_voice_actors (JOB 10a)", materialized: RussianVoiceActorsView },
  { name: "voicing_actresses (JOB 19d)", materialized: VoicingActressesView }
].freeze

ITERATIONS = Integer(ENV.fetch("BENCH_ITERATIONS", "5"))

def timed(_label)
  times = []
  result = nil
  ITERATIONS.times do
    elapsed = Benchmark.realtime { result = yield }
    times << elapsed
  end
  avg = times.sum / times.size
  [avg, result, times]
end

puts "=" * 72
puts "ActiveRecord::Materialized Benchmark"
puts "Database: #{db_path}"
puts "Iterations per query: #{ITERATIONS}"
puts "=" * 72

results = QUERIES.map do |query|
  print "Bootstrap refresh (one-time) for #{query[:name]}..."
  refresh_result = query[:materialized].rebuild!(confirm: true)
  puts " #{refresh_result.row_count} rows in #{refresh_result.duration_ms}ms"

  # Build a fresh relation per iteration. An ActiveRecord::Relation memoizes its
  # rows once loaded, so reusing one object measures cached-array iteration
  # (~0ms) rather than the query — which made raw look faster than the MV (#40).
  raw_avg, raw_result, = timed("raw") { query[:materialized].resolved_source.map(&:attributes) }
  mv_avg, mv_result, = timed("materialized") { query[:materialized].all.map(&:attributes) }

  speedup = mv_avg.zero? ? Float::INFINITY : raw_avg / mv_avg
  {
    name: query[:name],
    raw_avg: raw_avg,
    mv_avg: mv_avg,
    refresh_ms: refresh_result.duration_ms,
    raw_rows: raw_result.size,
    mv_rows: mv_result.size,
    speedup: speedup
  }
end

puts
BenchmarkSupport::TableFormatter.print_compare_header
puts "-" * 72
results.each do |row|
  BenchmarkSupport::TableFormatter.print_compare_row(
    query: row[:name],
    raw: row[:raw_avg],
    mv_read: row[:mv_avg],
    refresh: row[:refresh_ms],
    speedup: row[:speedup]
  )
end

puts
puts "Bootstrap refresh is a one-time full materialization cost per view."
puts "For write → incremental maintenance → updated read timing, run: rake benchmark:verify_updates"
puts "Materialized views trade bootstrap cost for dramatically faster reads."
