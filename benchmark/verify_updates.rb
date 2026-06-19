# frozen_string_literal: true

require_relative "support/benchmark_connection"
require_relative "support/dataset_info"
require "benchmark"

class UpdateVerificationError < StandardError; end

def assert_condition!(message, condition)
  raise UpdateVerificationError, message unless condition
end

def female_pairing_total(view)
  view.where(gender: "f").pick(:role_pairings).to_i
end

def create_simulated_cast_row!(max_cast_id, offset, female_ids, movie_ids)
  Job::CastInfo.create!(
    id: max_cast_id + offset + 1,
    person_id: female_ids[offset % female_ids.size],
    movie_id: movie_ids[offset % movie_ids.size],
    person_role_id: 1,
    note: "update-simulation",
    nr_order: offset % 20,
    role_id: 2
  )
end

def insert_synthetic_cast_rows!(count:)
  max_cast_id = Job::CastInfo.maximum(:id).to_i
  female_ids = Job::Name.where(gender: "f").limit(100).pluck(:id)
  movie_ids = Job::Title.where(Job::Title.arel_table[:production_year].gt(2000)).limit(100).pluck(:id)

  assert_condition!("Need seed names and titles for update simulation", female_ids.any? && movie_ids.any?)

  ActiveRecord::Base.transaction do
    count.times { |offset| create_simulated_cast_row!(max_cast_id, offset, female_ids, movie_ids) }
  end

  count
end

def print_summary_row(label, time, count)
  printf("%<label>-36s %<time>14s %<count>14s\n", label: label, time: time, count: count)
end

def print_summary_count_row(label, time, count)
  printf("%<label>-36s %<time>14s %<count>14d\n", label: label, time: time, count: count)
end

def time_raw_gender_query
  relation = GenderPairingStatsView.resolved_source
  elapsed, result = BenchmarkSupport.timed(iterations: 1) { relation.map(&:attributes) }
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

stale_read_time = Benchmark.realtime { @stale_total = female_pairing_total(view) }
assert_condition!(
  "Reads before background refresh should stay fast (#{(stale_read_time * 1000).round(2)}ms)",
  stale_read_time < 0.05
)
stale_ms = (stale_read_time * 1000).round(2)
puts "4) Read before refresh completes: #{stale_ms}ms (still #{@stale_total}, stale snapshot OK)"

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
print_summary_row("Stage", "Time", "female pairings")
puts "-" * 66
print_summary_count_row("Cached read (pre-update)", "#{(mv_read_before_avg * 1000).round(2)}ms", baseline)
print_summary_count_row("Cached read (before refresh)", "#{(stale_read_time * 1000).round(2)}ms", @stale_total)
print_summary_count_row("Background refresh (on write)", "#{(refresh_time * 1000).round(0)}ms", refreshed_total)
print_summary_count_row("Cached read (post-refresh)", "#{(mv_read_after_avg * 1000).round(2)}ms", refreshed_total)
print_summary_count_row("Raw query (reference)", "#{raw_after_avg.round(3)}s", raw_female_total)
puts
puts "Verification passed: writes trigger refresh; user reads stay fast."
