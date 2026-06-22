# Changelog

## 0.1.0 (2026-06-18)

Initial release.

### Features

- Application-level materialized views for ActiveRecord (Rails 8+, Ruby 3.4+)
- Refresh-on-write: dependency changes schedule incremental background maintenance; reads never block on a rebuild
- Never an implicit full rebuild — a full materialization happens only via the explicit `rebuild!(confirm: true)` / `materialized:rebuild`, so launching against a large database is safe
- Read-through cold reads (`cold_read :read_through` default): reads on a not-yet-built view serve correct results from the source query; `:serve_stale` and `:raise` are also available
- Per-partition freshness: a cold view materializes individual `GROUP BY` partitions on demand (keyed reads and dependency writes), serving those partitions from the cache while the rest read through — partial materialization without ever a full rebuild
- Transparent ActiveRecord query interface (`where`, `find`, `count`, scopes)
- Declarative `materialized_from` sources defined as an `ActiveRecord::Relation` (via a block)
- `depends_on` dependency tracking via ActiveRecord `after_*_commit` callbacks
- Refresh strategies: `:async` (default), `:immediate`, `:manual`
- Debounced async refresh with in-process `AsyncRefresher` or ActiveJob dispatcher
- Atomic table-swap on `rebuild!` (`CREATE TABLE AS` + rename) for a consistent full materialization
- Incremental view maintenance (IVM) for `GROUP BY` views — never a routine table rebuild:
  - **Summary-delta** maintenance for distributive views (`SUM` / `COUNT` / `COUNT(*)`): writes apply signed per-partition deltas to the cache table without re-reading base rows, with NULL-safe sums and empty-partition deletion
  - **Scoped recompute** (partition-local delete + re-aggregate) for everything else — `AVG`, `MIN`, `MAX`, `COUNT(DISTINCT)`, joins, `HAVING` — always correct
- Metadata tracking (`dirty`, `last_refreshed_at`, `row_count`, `refresh_duration_ms`, errors)
- Optional `max_staleness` time-based safety net
- `before_refresh` / `after_refresh` callbacks
- Migration-provisioned cache tables: `activerecord_materialized:migration <View>` generates a `create_table` migration with columns/types inferred from the source relation, so the table exists at deploy time
- Boot/CI schema drift verification (`materialized:verify` / `ActiveRecord::Materialized.verify_schema!`) raises a helpful error when a view's table no longer matches its relation — never auto-alters
- Rails generators: `activerecord_materialized:install`, `activerecord_materialized:view`, `activerecord_materialized:migration`
- Rake tasks: `materialized:refresh_all`, `materialized:refresh_stale`, `materialized:rebuild`, `materialized:verify`
- JOB-schema benchmark suite with multi-second analytical queries on SQLite

### Benchmark highlights (xlarge dataset, ~2M cast_info rows)

- Raw queries: 7–20 seconds
- Materialized view reads: ~0.3–0.7ms
- Speedup: 20,000–49,000×
