# frozen_string_literal: true

require_relative "support/benchmark_connection"
require_relative "support/dataset_info"
require_relative "support/table_formatter"
require "benchmark"

class UpdateVerificationError < StandardError; end

def assert_condition!(message, condition)
  raise UpdateVerificationError, message unless condition
end

def female_pairing_total(view)
  view.where(gender: "f").pick(:role_pairings).to_i
end

def insert_cast_row(connection, cast_id, person_id, movie_id, offset)
  connection.execute(
    "INSERT INTO cast_info (id, person_id, movie_id, person_role_id, note, nr_order, role_id) " \
    "VALUES (#{cast_id}, #{person_id}, #{movie_id}, 1, 'update-simulation', #{offset % 20}, 2)"
  )
end

def cast_seed_ids(connection)
  female_ids = connection.select_values("SELECT id FROM name WHERE gender = 'f' LIMIT 100")
  movie_ids = connection.select_values("SELECT id FROM title WHERE production_year > 2000 LIMIT 100")
  [female_ids, movie_ids]
end

def insert_cast_rows_batch(connection, count, max_cast_id, female_ids, movie_ids)
  connection.transaction do
    count.times do |offset|
      cast_id = max_cast_id + offset + 1
      person_id = female_ids[offset % female_ids.size]
      movie_id = movie_ids[offset % movie_ids.size]
      insert_cast_row(connection, cast_id, person_id, movie_id, offset)
    end
  end
end

def insert_synthetic_cast_rows!(count:)
  connection = ActiveRecord::Base.connection
  max_cast_id = connection.select_value("SELECT COALESCE(MAX(id), 0) FROM cast_info").to_i
  female_ids, movie_ids = cast_seed_ids(connection)

  assert_condition!("Need seed names and titles for update simulation", female_ids.any? && movie_ids.any?)
  insert_cast_rows_batch(connection, count, max_cast_id, female_ids, movie_ids)
  count
end

def time_raw_gender_query
  sql = File.read(BenchmarkSupport::BENCHMARK_ROOT.join("queries", "gender_pairing_stats.sql"))
  elapsed, result = BenchmarkSupport.timed(iterations: 1) { ActiveRecord::Base.connection.select_all(sql).to_a }
  [elapsed, result]
end

db_path = BenchmarkSupport.connect!
stats = BenchmarkSupport::DatasetInfo.collect(db_path: db_path)

puts "=" * 80
puts "ActiveRecord::Materialized — Refresh-on-Write Verification"
puts "Database: #{db_path}"
puts "Model: writes schedule refresh; reads always hit cache"
puts "=" * 80
BenchmarkSupport::DatasetInfo.print_report(stats)

view = GenderPairingStatsView

print "1) Warm cache via background refresh..."
ActiveRecord::Materialized::AsyncRefresher.flush! if view.dirty?
view.refresh! unless view.table_exists?
baseline = female_pairing_total(view)
puts " female role_pairings=#{baseline}"

mv_read_before_avg, = BenchmarkSupport.timed(iterations: 5) { female_pairing_total(view) }
puts "2) Cached MV reads: #{(mv_read_before_avg * 1000).round(2)}ms avg"

inserted = insert_synthetic_cast_rows!(count: Integer(ENV.fetch("UPDATE_INSERT_COUNT", "8000")))
puts "3) Inserted #{inserted} cast_info rows (refresh scheduled on commit)"

assert_condition!("View should be marked dirty after write", view.dirty?)

stale_total = nil
stale_read_time = Benchmark.realtime { stale_total = female_pairing_total(view) }
assert_condition!(
  "Reads before background refresh should stay fast (#{(stale_read_time * 1000).round(2)}ms)",
  stale_read_time < 0.05
)
stale_ms = (stale_read_time * 1000).round(2)
puts "4) Read before refresh completes: #{stale_ms}ms (still #{stale_total}, stale snapshot OK)"

print "5) Running scheduled background refresh..."
refresh_time = Benchmark.realtime { ActiveRecord::Materialized::AsyncRefresher.flush! }
refreshed_total = female_pairing_total(view)
raw_after_avg, raw_after_rows = time_raw_gender_query
raw_female_total = raw_after_rows.find { |row| row["gender"] == "f" }&.fetch("role_pairings").to_i
assert_condition!(
  "Background refresh should match raw query (mv=#{refreshed_total}, raw=#{raw_female_total})",
  refreshed_total == raw_female_total
)
assert_condition!("Refreshed total should exceed baseline", refreshed_total > baseline)
puts " #{(refresh_time * 1000).round(0)}ms, female role_pairings=#{refreshed_total}"

mv_read_after_avg, = BenchmarkSupport.timed(iterations: 5) { female_pairing_total(view) }
assert_condition!("Post-refresh reads should stay fast", mv_read_after_avg < 0.05)
puts "6) Cached MV reads after refresh: #{(mv_read_after_avg * 1000).round(2)}ms avg"

puts
BenchmarkSupport::TableFormatter.print_verify_header
puts "-" * 66
BenchmarkSupport::TableFormatter.print_verify_row(
  stage: "Cached read (pre-update)",
  time: "#{(mv_read_before_avg * 1000).round(2)}ms",
  pairings: baseline
)
BenchmarkSupport::TableFormatter.print_verify_row(
  stage: "Cached read (before refresh)",
  time: "#{(stale_read_time * 1000).round(2)}ms",
  pairings: stale_total
)
BenchmarkSupport::TableFormatter.print_verify_row(
  stage: "Background refresh (on write)",
  time: "#{(refresh_time * 1000).round(0)}ms",
  pairings: refreshed_total
)
BenchmarkSupport::TableFormatter.print_verify_row(
  stage: "Cached read (post-refresh)",
  time: "#{(mv_read_after_avg * 1000).round(2)}ms",
  pairings: refreshed_total
)
BenchmarkSupport::TableFormatter.print_verify_row(
  stage: "Raw query (reference)",
  time: "#{raw_after_avg.round(3)}s",
  pairings: raw_female_total
)
puts
puts "Verification passed: writes trigger refresh; user reads stay fast."
