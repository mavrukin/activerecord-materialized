# Changelog

## 0.1.0 (2026-06-18)

Initial release.

### Features

- Application-level materialized views for ActiveRecord (Rails 8+, Ruby 3.4+)
- Refresh-on-write: dependency changes schedule background refresh; reads never block on rebuild
- Transparent ActiveRecord query interface (`where`, `find`, `count`, scopes)
- Declarative `materialized_from` source SQL with callable support
- `depends_on` dependency tracking via `sql.active_record` instrumentation
- Refresh strategies: `:async` (default), `:immediate`, `:manual`
- Debounced async refresh with in-process `AsyncRefresher` or ActiveJob dispatcher
- Atomic table-swap bootstrap (`CREATE TABLE AS` + rename) when cache table is first created
- Default incremental maintenance (IVM) for `GROUP BY` views — partition-local delete + re-aggregate, no routine table rebuild
- Metadata tracking (`dirty`, `last_refreshed_at`, `row_count`, `refresh_duration_ms`, errors)
- Optional `max_staleness` time-based safety net
- `before_refresh` / `after_refresh` callbacks
- Rails generators: `activerecord_materialized:install`, `activerecord_materialized:view`
- Rake tasks: `materialized:refresh_all`, `materialized:refresh_stale`
- JOB-schema benchmark suite with multi-second analytical queries on SQLite

### Benchmark highlights (xlarge dataset, ~2M cast_info rows)

- Raw queries: 7–20 seconds
- Materialized view reads: ~0.3–0.7ms
- Speedup: 20,000–49,000×
