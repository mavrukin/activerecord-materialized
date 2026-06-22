# frozen_string_literal: true

require_relative "support/benchmark_connection"
require_relative "support/cast_simulation"
require_relative "support/dataset_info"
require_relative "support/sql_execution_recorder"
require_relative "support/table_formatter"
require "benchmark"

class UpdateVerificationError < StandardError; end

def assert_condition!(message, condition)
  raise UpdateVerificationError, message unless condition
end

def female_pairing_total(view)
  view.where(gender: "f").pick(:role_pairings).to_i
end

def print_summary_count_row(label, time, count)
  BenchmarkSupport::TableFormatter.print_verify_row(stage: label, time: time, pairings: count)
end

def time_raw_gender_query
  relation = GenderPairingStatsView.resolved_source
  elapsed, result = BenchmarkSupport.timed(iterations: 1) { relation.map(&:attributes) }
  [elapsed, result]
end

db_path = BenchmarkSupport.connect!
stats = BenchmarkSupport::DatasetInfo.collect(db_path: db_path)

puts "=" * 80
puts "ActiveRecord::Materialized — Incremental Maintenance Verification"
puts "Database: #{db_path}"
puts "Flow: bootstrap once → writes accumulate partitions → in-place maintenance → updated reads"
puts "=" * 80
BenchmarkSupport::DatasetInfo.print_report(stats)

view = GenderPairingStatsView
view.metadata.clear_maintenance_payload!

# Drive maintenance explicitly: the view refreshes :async with debounce 0, so a
# background refresh would fire per committed row. Accumulate, refresh once (#40).
ActiveRecord::Materialized::AsyncRefresher.paused = true

connection = ActiveRecord::Base.connection
bootstrap_ms = nil

if view.table_exists?
  puts "1) Cache table present — skipping bootstrap"
else
  print "1) Bootstrap (one-time atomic swap)..."
  bootstrap_recorder = BenchmarkSupport::SqlExecutionRecorder.new.install!(connection)
  bootstrap_result = view.rebuild!(confirm: true)
  bootstrap_ms = bootstrap_result.duration_ms
  assert_condition!(
    "Bootstrap should use atomic swap",
    bootstrap_recorder.bootstrap_swap_detected?
  )
  puts " #{bootstrap_result.row_count} rows in #{bootstrap_ms}ms"
end

ActiveRecord::Materialized::AsyncRefresher.reset!
ActiveRecord::Materialized::AsyncRefresher.flush! if view.dirty?
baseline = female_pairing_total(view)
puts "   female role_pairings=#{baseline}"

mv_read_before_avg, = BenchmarkSupport.timed(iterations: 5) { female_pairing_total(view) }
puts "2) Cached MV reads (pre-update): #{(mv_read_before_avg * 1000).round(2)}ms avg"

inserted = BenchmarkSupport::CastSimulation.insert_rows!(count: Integer(ENV.fetch("UPDATE_INSERT_COUNT", "8000")))
puts "3) Inserted #{inserted} cast_info rows (partition scope accumulated on commit)"

assert_condition!("View should be marked dirty after write", view.dirty?)

stale_read_time = Benchmark.realtime { @stale_total = female_pairing_total(view) }
assert_condition!(
  "Reads before maintenance should stay fast (#{(stale_read_time * 1000).round(2)}ms)",
  stale_read_time < 0.05
)
assert_condition!(
  "Stale read should return pre-update snapshot",
  @stale_total == baseline
)
puts "4) Read before maintenance: #{(stale_read_time * 1000).round(2)}ms (snapshot=#{@stale_total}, unchanged)"

print "5) Incremental maintenance (in-place partition merge)..."
ActiveRecord::Materialized::AsyncRefresher.reset!
maintenance_recorder = BenchmarkSupport::SqlExecutionRecorder.new.install!(connection)
maintenance_time = Benchmark.realtime { view.refresh! }
refreshed_total = female_pairing_total(view)
assert_condition!(
  "Routine maintenance must not rebuild or swap the cache table",
  !maintenance_recorder.bootstrap_swap_detected?
)
assert_condition!(
  "Incremental maintenance should rewrite affected partitions in place",
  maintenance_recorder.incremental_maintenance_detected?
)
assert_condition!("View should be clean after maintenance", !view.dirty?)

raw_after_avg, raw_after_rows = time_raw_gender_query
raw_female_total = raw_after_rows.find { |row| row["gender"] == "f" }&.fetch("role_pairings").to_i
assert_condition!(
  "Maintained MV should match source relation (mv=#{refreshed_total}, raw=#{raw_female_total})",
  refreshed_total == raw_female_total
)
assert_condition!("Maintained total should exceed baseline", refreshed_total > baseline)
puts " #{(maintenance_time * 1000).round(0)}ms, female role_pairings=#{refreshed_total}"

mv_read_after_avg, = BenchmarkSupport.timed(iterations: 5) { female_pairing_total(view) }
assert_condition!("Post-maintenance reads should stay fast", mv_read_after_avg < 0.05)
assert_condition!(
  "Post-maintenance read should return updated snapshot",
  female_pairing_total(view) == refreshed_total
)
puts "6) Cached MV reads (post-maintenance): #{(mv_read_after_avg * 1000).round(2)}ms avg, value=#{refreshed_total}"

puts
BenchmarkSupport::TableFormatter.print_verify_header
puts "-" * 66
print_summary_count_row("Bootstrap (one-time)", "#{bootstrap_ms}ms", 0) if bootstrap_ms
print_summary_count_row("Cached read (pre-update)", "#{(mv_read_before_avg * 1000).round(2)}ms", baseline)
print_summary_count_row("Cached read (stale)", "#{(stale_read_time * 1000).round(2)}ms", @stale_total)
print_summary_count_row("Incremental maintenance", "#{(maintenance_time * 1000).round(0)}ms", refreshed_total)
print_summary_count_row("Cached read (updated)", "#{(mv_read_after_avg * 1000).round(2)}ms", refreshed_total)
print_summary_count_row("Source relation (reference)", "#{raw_after_avg.round(3)}s", raw_female_total)
puts
puts "Verification passed: bootstrap once; writes trigger in-place maintenance;"
puts "reads stay fast (stale then updated); no cache-table rebuild on hot path."
