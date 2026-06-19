# frozen_string_literal: true

require_relative "support/benchmark_connection"
require_relative "support/dataset_info"
require_relative "support/sql_execution_recorder"
require "benchmark"

class UpdateVerificationError < StandardError; end

def assert_condition!(message, condition)
  raise UpdateVerificationError, message unless condition
end

def female_pairing_total(view)
  view.where(gender: "f").pick(:role_pairings).to_i
end

def insert_synthetic_cast_rows!(count:)
  connection = ActiveRecord::Base.connection
  max_cast_id = connection.select_value("SELECT COALESCE(MAX(id), 0) FROM cast_info").to_i
  female_ids = connection.select_values("SELECT id FROM name WHERE gender = 'f' LIMIT 100")
  movie_ids = connection.select_values("SELECT id FROM title WHERE production_year > 2000 LIMIT 100")

  assert_condition!("Need seed names and titles for update simulation", female_ids.any? && movie_ids.any?)

  connection.transaction do
    count.times do |offset|
      cast_id = max_cast_id + offset + 1
      person_id = female_ids[offset % female_ids.size]
      movie_id = movie_ids[offset % movie_ids.size]
      connection.execute(
        "INSERT INTO cast_info (id, person_id, movie_id, person_role_id, note, nr_order, role_id) " \
        "VALUES (#{cast_id}, #{person_id}, #{movie_id}, 1, 'update-simulation', #{offset % 20}, 2)"
      )
    end
  end

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
puts "ActiveRecord::Materialized — Incremental Maintenance Verification"
puts "Database: #{db_path}"
puts "Flow: bootstrap once → writes accumulate partitions → in-place maintenance → updated reads"
puts "=" * 80
BenchmarkSupport::DatasetInfo.print_report(stats)

view = GenderPairingStatsView
view.metadata.clear_maintenance_payload!

connection = ActiveRecord::Base.connection
bootstrap_ms = nil

if view.table_exists?
  puts "1) Cache table present — skipping bootstrap"
else
  print "1) Bootstrap (one-time CREATE TABLE AS + atomic swap)..."
  bootstrap_recorder = BenchmarkSupport::SqlExecutionRecorder.new.install!(connection)
  bootstrap_result = view.refresh!
  bootstrap_ms = bootstrap_result.duration_ms
  assert_condition!(
    "Bootstrap should use atomic swap",
    bootstrap_recorder.bootstrap_swap_detected?
  )
  puts " #{bootstrap_result.row_count} rows in #{bootstrap_ms}ms"
end

ActiveRecord::Materialized::AsyncRefresher.flush! if view.dirty?
baseline = female_pairing_total(view)
puts "   female role_pairings=#{baseline}"

mv_read_before_avg, = BenchmarkSupport.timed(iterations: 5) { female_pairing_total(view) }
puts "2) Cached MV reads (pre-update): #{(mv_read_before_avg * 1000).round(2)}ms avg"

# Hold refresh until we have measured stale reads; debounce 0 would otherwise
# complete maintenance in a background thread before those assertions run.
view.refresh_on_change :manual
inserted = insert_synthetic_cast_rows!(count: Integer(ENV.fetch("UPDATE_INSERT_COUNT", "8000")))
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
  "Incremental maintenance should use temp partition re-aggregation",
  maintenance_recorder.incremental_maintenance_detected?
)
assert_condition!("View should be clean after maintenance", !view.dirty?)

raw_after_avg, raw_after_rows = time_raw_gender_query
raw_female_total = raw_after_rows.find { |row| row["gender"] == "f" }&.fetch("role_pairings").to_i
assert_condition!(
  "Maintained MV should match raw query (mv=#{refreshed_total}, raw=#{raw_female_total})",
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
printf("%-36s %14s %14s\n", "Stage", "Time", "female pairings")
puts "-" * 66
if bootstrap_ms
  printf("%-36s %14s %14s\n", "Bootstrap (one-time)", "#{bootstrap_ms}ms", "—")
end
printf("%-36s %14s %14d\n", "Cached read (pre-update)", "#{(mv_read_before_avg * 1000).round(2)}ms", baseline)
printf("%-36s %14s %14d\n", "Cached read (stale)", "#{(stale_read_time * 1000).round(2)}ms", @stale_total)
printf("%-36s %14s %14d\n", "Incremental maintenance", "#{(maintenance_time * 1000).round(0)}ms", refreshed_total)
printf("%-36s %14s %14d\n", "Cached read (updated)", "#{(mv_read_after_avg * 1000).round(2)}ms", refreshed_total)
printf("%-36s %14s %14d\n", "Raw query (reference)", "#{raw_after_avg.round(3)}s", raw_female_total)
puts
puts "Verification passed: bootstrap once; writes trigger in-place maintenance;"
puts "reads stay fast (stale then updated); no cache-table rebuild on hot path."
