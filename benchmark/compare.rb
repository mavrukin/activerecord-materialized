# frozen_string_literal: true

require "active_record"
require "benchmark"
require "pathname"

BENCHMARK_ROOT = Pathname.new(__dir__).expand_path
GEM_ROOT = BENCHMARK_ROOT.join("..").expand_path
$LOAD_PATH.unshift GEM_ROOT.join("lib").to_s
require "activerecord-materialized"

DB_PATH = ENV.fetch("JOB_DB", BENCHMARK_ROOT.join("fixtures", "job.sqlite").to_s)

unless File.exist?(DB_PATH)
  warn "Database not found at #{DB_PATH}. Run: rake benchmark:setup"
  load BENCHMARK_ROOT.join("scripts", "generate_job_database.rb").to_s
end

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: DB_PATH
)

class JobRecord < ActiveRecord::Base
  self.abstract_class = true
end

Dir[BENCHMARK_ROOT.join("models", "*.rb")].sort.each { |file| require file }
Dir[BENCHMARK_ROOT.join("materialized_models", "*.rb")].sort.each { |file| require file }

QUERIES = [
  {
    name: "gender_pairing_stats (slow)",
    raw_sql_file: "gender_pairing_stats.sql",
    materialized: GenderPairingStatsView
  },
  {
    name: "company_movie_cross (slow)",
    raw_sql_file: "company_movie_cross.sql",
    materialized: CompanyMovieCrossView
  },
  {
    name: "person_movie_network (slow)",
    raw_sql_file: "person_movie_network.sql",
    materialized: PersonMovieNetworkView
  },
  {
    name: "production_notes (JOB 1a)",
    raw_sql_file: "production_notes.sql",
    materialized: ProductionNotesView
  },
  {
    name: "russian_voice_actors (JOB 10a)",
    raw_sql_file: "russian_voice_actors.sql",
    materialized: RussianVoiceActorsView
  },
  {
    name: "voicing_actresses (JOB 19d)",
    raw_sql_file: "voicing_actresses.sql",
    materialized: VoicingActressesView
  }
].freeze

ITERATIONS = Integer(ENV.fetch("BENCH_ITERATIONS", "5"))

def timed(label)
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
puts "Database: #{DB_PATH}"
puts "Iterations per query: #{ITERATIONS}"
puts "=" * 72

results = QUERIES.map do |query|
  raw_sql = File.read(BENCHMARK_ROOT.join("queries", query[:raw_sql_file]))

  print "Bootstrap refresh (one-time) for #{query[:name]}..."
  refresh_result = query[:materialized].refresh!
  puts " #{refresh_result.row_count} rows in #{refresh_result.duration_ms}ms"

  raw_avg, raw_result, = timed("raw") { ActiveRecord::Base.connection.select_all(raw_sql).to_a }
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
printf("%-35s %12s %12s %10s %8s\n", "Query", "Raw (s)", "MV read (s)", "Bootstrap(ms)", "Speedup")
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
puts "Bootstrap refresh is a one-time full materialization cost per view."
puts "For write → incremental maintenance → updated read timing, run: rake benchmark:verify_updates"
puts "Materialized views trade bootstrap cost for dramatically faster reads."
