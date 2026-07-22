# Data integrity: drift detection & self-healing

Verify a materialized view against its source relation to catch data that has diverged, then bound how stale any view can get by scoped-repairing that drift on a schedule.

## Detecting data drift

`materialized:verify` checks a cache table's **schema** against its source. To
detect **data** drift — the materialized contents diverging from what the source
relation would produce now (e.g. because a write slipped past the change source) —
use the data-verification API. It recomputes the source and compares it to the
cache per partition, reporting the divergent partition keys. It never alters data.
Both the cache and the recomputed source are read through the **cache model's own
column types**, so a value that reads back through two different type systems (a
date key, an integer/decimal column, a computed source aggregate) isn't mistaken
for drift; duplicate cache rows for a partition are caught rather than collapsed. It
covers grouped/aggregate views — a non-grouped view, a schema-drifted cache, or one
whose `GROUP BY` key can't be matched to a projected column is skipped. (An
un-scaled decimal aggregate can still differ in trailing float precision; give such
a column an explicit scale to compare it soundly.)

```ruby
# One view, programmatically — returns a DataVerificationResult.
result = ActiveRecord::Materialized::DataVerifier.new(SalesSummary, mode: :checksum).verify
result.drifted?        # => true/false
result.mismatched_keys # => partitions whose values differ
result.missing_keys    # => in the source, absent from the cache
result.extra_keys      # => in the cache, absent from the source

# All registered views — array of results, or verify_data! to raise on drift.
ActiveRecord::Materialized.verify_data(mode: :checksum)
ActiveRecord::Materialized.verify_data!(mode: :full)   # boot/CI/cron gate; raises DataDriftError
```

Modes trade cost for depth:

| Mode | Compares | Use when |
|------|----------|----------|
| `:row_count` | Which partitions exist, and each partition's row count (missing/extra partitions, plus duplicated/lost rows via `mismatched_keys`) | Cheapest structural check |
| `:checksum` | A per-partition digest of the value columns | Wide rows; detect value drift compactly |
| `:full` | The value columns exactly | Exhaustive / debuggable |

For large views, `sample:` (an Integer count or a Float fraction) is a cheap
periodic probe: it value-checks a random subset of **materialized** partitions and
reports coverage (`checked_partition_count` / `total_partition_count`). Because it
only looks at partitions already in the cache, it detects value drift and extra
partitions but **not missing (source-only) partitions** — use full mode (or a
sample covering every partition, which runs exhaustively) for completeness. The
returned partition keys are what a repair step re-maintains (see self-healing
reconciliation).

Rake: `bin/rails materialized:audit` runs `verify_data!` across all views.

---

## Bounded staleness and self-healing

Any change source can miss a write — callbacks miss bulk/raw writes, and even a CDC
stream can drop or lag. Left alone, a missed write leaves a partition wrong
indefinitely. **Reconciliation** turns that unbounded drift into bounded,
self-correcting staleness: on a schedule it verifies each view (via [data-drift
detection](#detecting-data-drift)) and repairs whatever diverged — re-aggregating
missing/mismatched partitions and dropping extra ones — using **scoped** maintenance,
never a full `rebuild!`.

```ruby
# One view: drain pending maintenance, verify, and repair any drift. Returns a ReconcileResult.
result = SalesSummary.reconcile!(mode: :checksum)
result.repaired?                # => true when drift was found and repaired
result.repaired_partition_count # => how many partitions were repaired

# All registered views, or only the stale ones (the scheduled backstop).
ActiveRecord::Materialized.reconcile!(mode: :checksum)         # every view
ActiveRecord::Materialized.reconcile_stale!(mode: :checksum)   # dirty / past max_staleness only
```

Run `materialized:reconcile` (which calls `reconcile_stale!`) periodically from cron
or ActiveJob. It reconciles only **stale** views — dirty, never refreshed, or past
their [`max_staleness`](api-reference.md#dsl) — so the window between a missed write and its repair is
bounded by your schedule interval and each view's `max_staleness`, at the cost of one
drift check per stale view per tick. Use `sample:` (see [data drift](#detecting-data-drift))
to bound that cost on large views.

Reconciliation is safe to run alongside normal refresh. It drains pending maintenance
first (so it repairs genuinely-missed writes, not maintenance merely not yet applied),
and repairs through the same guarded, transactional maintenance path — so an
overlapping refresh can neither corrupt the cache nor double-maintain. When a refresh
already holds the view's cycle, the scoped repair is **deferred**
(`ReconcileResult#deferred`): it is durably queued and drained by that cycle or the
next tick, never lost. A full `rebuild!` remains the explicit escape hatch, and
`cold_read :read_through` stays the always-correct fallback while a partition is being
repaired.

A clean reconcile resets the staleness clock (`last_reconciled_at`), so a drift-free
view is not re-verified every tick. In a batch run, a failure reconciling one view is
isolated on its `ReconcileResult#error` rather than aborting the rest of the fleet.
Each run stamps `last_reconciled_at` / `reconciled_partition_count` on the view's
metadata and emits a [`reconcile.active_record_materialized`](observability.md) event.

---

[← Back to the README](../README.md)
