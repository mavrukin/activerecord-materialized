# frozen_string_literal: true

require "benchmark"
require_relative "support/benchmark_connection"
require_relative "support/cast_simulation"
require_relative "support/dataset_info"

# End-to-end lifecycle simulation of how an application actually uses a
# materialized view, on whatever scale database is present (xlarge recommended):
#
#   1. cold read  — no materialized data yet, served by read-through
#   2. build      — explicit rebuild! (the only full scan)
#   3. fast read  — cache vs the raw source query
#   4. write      — dependency writes -> background maintenance -> updated read
#   5. warm-up    — pre-materialize one hot partition, leave the rest cold
#
# Each phase prints the real result values (not just timings) and asserts the
# behaviour, so a green run is proof the whole flow works as advertised.

class LifecycleError < StandardError; end

def assert!(message, condition)
  raise LifecycleError, message unless condition
end

def section(title)
  puts
  puts "-" * 80
  puts title
  puts "-" * 80
end

def female_pairings(view = VIEW)
  view.where(gender: "f").pick(:role_pairings).to_i
end

def raw_female_pairings
  row = VIEW.resolved_source.map(&:attributes).find { |attributes| attributes["gender"] == "f" }
  row.fetch("role_pairings").to_i
end

def unbuild!(view)
  view.connection.drop_table(view.table_name, if_exists: true)
  view.reset_column_information
  view.metadata.record.update!(warm: false, dirty: true, last_refreshed_at: nil, row_count: nil)
  ActiveRecord::Materialized::PartitionState.new(view).reset!
end

db_path = BenchmarkSupport.connect!
stats = BenchmarkSupport::DatasetInfo.collect(db_path: db_path)

VIEW = GenderPairingStatsView
INSERTS = Integer(ENV.fetch("UPDATE_INSERT_COUNT", "8000"))

puts "=" * 80
puts "ActiveRecord::Materialized — Lifecycle Simulation"
puts "Database: #{db_path}"
puts "=" * 80
BenchmarkSupport::DatasetInfo.print_report(stats)

# Maintenance is driven explicitly so the run is deterministic; nothing about the
# flow depends on the in-process refresher's timing.
ActiveRecord::Materialized::AsyncRefresher.paused = true
timeline = []

# 1) Cold read — the view has never been built; reads fall through to the source.
section "1) Cold read — no materialized data (read-through to the source)"
unbuild!(VIEW)
assert!("view should start cold", !VIEW.materialized?)
cold_time, cold_rows = BenchmarkSupport.timed(iterations: 1) { VIEW.order(:gender).to_a }
cold_value = VIEW.where(gender: "f").pick(:role_pairings).to_i
puts "  read-through returned #{cold_rows.size} group(s) in #{cold_time.round(2)}s (served from the source query)"
puts "  female role_pairings = #{cold_value}"
assert!("read-through result must match the source", cold_value == raw_female_pairings)
assert!("a read must never build the view", !VIEW.materialized?)
timeline << ["1. Cold read (read-through)", "#{cold_time.round(2)}s", cold_value]

# 2) Build — the one and only full materialization.
section "2) Build once — explicit rebuild! (the only full-scan path)"
build = VIEW.rebuild!(confirm: true)
puts "  materialized #{build.row_count} rows in #{build.duration_ms}ms"
assert!("view should be materialized after rebuild!", VIEW.materialized?)
baseline = female_pairings
timeline << ["2. Build (rebuild!)", "#{build.duration_ms}ms", baseline]

# 3) Fast reads — the payoff: a cache hit instead of the multi-second query.
section "3) Fast reads — cache vs the raw source query"
raw_time, = BenchmarkSupport.timed(iterations: 1) { VIEW.resolved_source.map(&:attributes) }
mv_time, = BenchmarkSupport.timed(iterations: 5) { female_pairings }
speedup = mv_time.zero? ? Float::INFINITY : raw_time / mv_time
puts format("  raw query: %.2fs    MV read: %.3fms    speedup: %dx", raw_time, mv_time * 1000, speedup.round)
puts "  materialized result:"
VIEW.order(:gender).each do |row|
  puts "    gender=#{row.gender || '(nil)'}  role_pairings=#{row.role_pairings}  people=#{row.distinct_people}"
end
timeline << ["3. Warm read (cached)", "#{(mv_time * 1000).round(3)}ms", baseline]

# 4) Writes -> background maintenance -> updated read.
section "4) Writes -> background maintenance -> updated read"
BenchmarkSupport::CastSimulation.insert_rows!(count: INSERTS)
puts "  inserted #{INSERTS} cast_info rows; view dirty? #{VIEW.dirty?}"
assert!("a dependency write should mark the view dirty", VIEW.dirty?)
stale = female_pairings
puts "  read before maintenance: #{stale} (still the pre-update snapshot, served fast)"
assert!("a stale read should return the previous snapshot", stale == baseline)
maintenance = Benchmark.realtime { VIEW.refresh! }
updated = female_pairings
puts "  read after maintenance:  #{updated} in #{(maintenance * 1000).round(0)}ms"
assert!("maintained MV must match the raw query", updated == raw_female_pairings)
assert!("maintained value should exceed the baseline", updated > baseline)
assert!("maintenance should leave the view clean", !VIEW.dirty?)
timeline << ["4. Updated read (maintained)", "#{(maintenance * 1000).round(0)}ms", updated]

# 5) Warm-up — pre-materialize one hot partition on a cold view; the rest stays
#    read-through until touched.
section "5) Warm-up — pre-materialize one hot partition, leave the rest cold"
unbuild!(VIEW)
VIEW.warm_up { [where(gender: "f")] }
warm = Benchmark.realtime { VIEW.warm_up! }
partitions = ActiveRecord::Materialized::PartitionState.new(VIEW)
warm_value = female_pairings
puts "  warmed the gender=f partition in #{(warm * 1000).round(0)}ms; fresh? #{partitions.all_fresh?([['f']])}"
puts "  gender=f now served from cache: role_pairings=#{warm_value}"
assert!("the warmed partition should be fresh", partitions.all_fresh?([["f"]]))
assert!("an untouched partition should stay cold", !partitions.all_fresh?([["m"]]))
assert!("the view as a whole stays cold (partial materialization)", !VIEW.materialized?)
timeline << ["5. Warm-up (hot partition)", "#{(warm * 1000).round(0)}ms", warm_value]

puts
puts "-" * 66
printf("%-34s %14s %14s\n", "Phase", "Time", "female pairings")
puts "-" * 66
timeline.each { |stage, time, value| printf("%-34s %14s %14d\n", stage, time, value) }
puts
puts "Lifecycle verified: cold read-through -> build -> fast reads -> write ->"
puts "in-place maintenance -> updated read -> partition warm-up. All assertions passed."
