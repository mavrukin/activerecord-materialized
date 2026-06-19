# frozen_string_literal: true

require_relative "support/benchmark_connection"

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
  source_relation = query[:materialized].resolved_source

  print "Refreshing materialized view for #{query[:name]}..."
  refresh_result = query[:materialized].refresh!
  puts " #{refresh_result.row_count} rows in #{refresh_result.duration_ms}ms"

  raw_avg, raw_result, = timed("raw") { source_relation.map(&:attributes) }
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
printf("%-35s %12s %12s %10s %8s\n", "Query", "Raw (s)", "MV read (s)", "Refresh(ms)", "Speedup")
puts "-" * 72
results.each do |row|
  printf(
    "%-35s %12.4f %12.4f %10d %8.1fx\n",
    row[:name],
    row[:raw_avg],
    row[:mv_avg],
    row[:refresh_ms],
    row[:speedup]
  )
end

puts
puts "Materialized views trade upfront refresh cost for dramatically faster reads."
puts "With infrequent base-table updates, this matches native materialized view semantics."
