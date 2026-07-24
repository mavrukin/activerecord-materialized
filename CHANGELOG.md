# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- **Incremental maintenance for `DISTINCT` lookups.** A view whose source is a `SELECT DISTINCT a, b`
  with no `GROUP BY` and no aggregate is now maintained incrementally: its projected columns are the
  partition key, so it partitions and scoped-recomputes exactly like `GROUP BY a, b` (through the
  always-correct partition-recompute path — there are no aggregates to summary-delta). This covers the
  canonical "distinct lookup" the gem exists to speed up; previously such a view had no detected group
  key and degraded to full-refresh-only. A projection that is not purely plain key columns (a raw-SQL
  expression, `DISTINCT *`, or `DISTINCT` combined with an aggregate) still falls back to full refresh.
  Cold ordinal finders (`first`/`last`) on a distinct view now order by its key columns too. (#146)
- **Pluggable change sources & CDC ingestion.** Change *detection* is now decoupled from view
  *maintenance* behind a public ingestion API — `publish_write_change!` and `mark_dirty_for_tables!`
  (with the lower-level `ingest_change` for a normalized change descriptor) — so a view can be fed
  from ActiveRecord callbacks (still the default), raw SQL, another service, or a CDC stream. Choose
  the source globally with `config.default_change_source` or per view with `change_source :none`;
  each view is fed by exactly one source. A dependency-free Debezium envelope adapter
  (`ingest_debezium_change`) maps a decoded change event straight into the pipeline, and optional
  monotonic **source watermarks** (`source_ts:`, exposed via `View.source_watermark`) suppress
  provably-stale out-of-order changes and surface per-view freshness/lag; Debezium's `source.ts_ms`
  is forwarded as that watermark automatically. Delivery is at-least-once and order-tolerant —
  duplicates and reordering converge. Validated end-to-end against real MySQL binlog and Postgres
  logical-replication decoding. See the [Change sources](docs/change-sources.md) docs.
  (#80, #105, #106, #113, #117, #118)
- **Out-of-band write capture via triggers/outbox.** A database-native outbox change source
  (`WriteOutbox.install_triggers!` + `drain_write_outbox!`, with an `activerecord_materialized:outbox`
  generator) captures writes that bypass both ActiveRecord callbacks and the ingestion API — raw SQL,
  bulk backfills, or another service on the shared database. Triggers record the changed `GROUP BY`
  key columns, scoped per operation so a partition-moving update maintains both the old and new
  partition, and draining is batched, at-least-once, and per-row isolated. Portable across Postgres,
  MySQL, and SQLite; opt-in. See the [detecting out-of-band writes](docs/out-of-band-writes.md) guide.
  (#68)
- **Self-healing reconciliation & data-drift detection.** A `DataVerifier`
  (`verify_data` / `verify_data!`, `materialized:audit`) recomputes the source per partition and
  reports `missing` / `extra` / `mismatched` keys, with `:row_count`, `:checksum`, and `:full` modes
  plus cheap sampling for large views. Built on it, self-healing reconciliation
  (`reconcile!` / `reconcile_stale!`, `materialized:reconcile`) verifies views on a schedule and
  **scoped-repairs** whatever the change source missed — never a full `rebuild!` — bounding staleness
  in time and composing with `max_staleness`. Reconciliation is safe alongside normal refresh: it
  drains pending maintenance first, defers rather than double-maintains when a refresh already holds
  the cycle, and isolates per-view failures. See
  [Data integrity: drift detection & self-healing](docs/reconciliation.md). (#62)
- **Distributed / HA maintenance.** New `enqueue_stale_refreshes!` / `enqueue_stale_reconciles!`
  (and matching rake tasks) fan the periodic bounded-staleness backstop out across the job fleet as
  one job per stale view, backed by a new `ReconcileJob` that re-checks staleness before working.
  Writer/replica topology support routes maintenance to the primary and verification reads to a
  replica (`config.maintenance_role` / `config.verification_role`), reads cache and source in a
  single snapshot to avoid false drift, and folds a `config.replica_lag` budget into `stale?`.
  Cross-process cycles are serialized by a metadata-row lock so concurrent servers apply additive
  deltas exactly once and recompute a partition once. Run the periodic tick from a single owner — the
  gem ships no scheduler or leader election. See the
  [distributed deployment](docs/distributed-deployment.md) docs. (#92, #93, #94, #95)
- **Observability via `ActiveSupport::Notifications`.** The read, refresh, and maintenance lifecycle
  points emit documented events (`read.active_record_materialized`,
  `refresh.active_record_materialized`, `maintenance.active_record_materialized`) with stable
  payloads — cache-hit vs read-through and staleness on reads; duration, mode, partitions recomputed,
  and outcome on refreshes; and a widen-to-full signal on writes. No telemetry-vendor dependency;
  read events fire only when a subscriber is attached. See the [Observability](docs/observability.md)
  docs.
- **Scoped maintenance for joined-table keys.** `partition_key_for(table) { |change| ... }` maps a
  write on a joined/leaf dependency table — whose own payload lacks the `GROUP BY` key — to the
  affected partition key(s), keeping maintenance scoped to those partitions instead of widening to a
  full recompute. See the [joined-table docs](docs/architecture.md#views-whose-group-key-lives-on-a-joined-table).

### Changed

- **`config.refresh_dispatcher` now auto-resolves to `:active_job` when ActiveJob is loaded**
  (previously the in-process `:async` thread), so a typical multi-server Rails deployment coordinates
  refresh across servers by default; an explicit `config.refresh_dispatcher` still wins.
  **Upgrade note:** ensure a worker drains `config.refresh_queue_name` (default `:materialized_views`)
  or set `config.refresh_dispatcher = :async` explicitly — otherwise refresh-on-write jobs enqueue
  with nothing to run them and views serve stale reads. A boot warning fires when the in-process
  refresher is active despite ActiveJob being available. `config.reconcile_queue_name` defaults to the
  refresh queue. (#93)

### Fixed

- **Cold-view widen correctness.** A full-partition (widen) recompute can't be applied to a never-built
  (cold) view; letting one through previously killed populate-on-read until a manual `rebuild!`. Every
  widen producer now funnels through a single `MaintenanceStore#merge!` chokepoint that drops the
  cold-view recompute and resets the fresh set, and a lock-free per-view **epoch**
  (`fresh_set_generation`) closes a populate-vs-widen race that could otherwise serve stale data on a
  cold view. Reads fall through to the always-correct source and repopulate on the next miss;
  warm/materialized views are unaffected. (#110, #120)
- **Partition-moving update under-scoping.** A CDC/ingestion `:update` with a partial `before`-image
  (no `GROUP BY` key — the common non-FULL image: Postgres default `REPLICA IDENTITY`, MySQL
  `binlog-row-image=minimal`) previously left the *old* partition stale. The delta builder now
  recognizes it cannot identify every affected partition from a partial image and widens to a full
  recompute, honoring the ingestion API's documented always-correct guarantee. Scoped updates with
  full before/after images (or `key_attributes`) are unchanged. (#110)

### Internal

- Shared per-partition-store base (`PartitionKeyedStore`) factored out of `PartitionState` and
  `SourceWatermark`, and documentation/tooling cleanup. (#115, #124)

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
- `rebuild!` materializes entirely in the database with `INSERT … SELECT` over the source query (atomic table swap), so the result set never crosses into Ruby memory — safe to run against a large dataset
- Warm-up: a `warm_up { [...] }` DSL plus `warm_up!` / `materialized:warm_up` materialize a cold view's hot partitions ahead of traffic, leaving the rest to read through on demand
- Incremental view maintenance (IVM) for `GROUP BY` views — never a routine table rebuild:
  - **Summary-delta** maintenance for distributive views (`SUM` / `COUNT` / `COUNT(*)`): writes apply signed per-partition deltas to the cache table without re-reading base rows, with NULL-safe sums and empty-partition deletion
  - **Scoped recompute** (partition-local delete + re-aggregate) for everything else — `AVG`, `MIN`, `MAX`, `COUNT(DISTINCT)`, joins, `HAVING` — always correct
- Metadata tracking (`dirty`, `last_refreshed_at`, `row_count`, `refresh_duration_ms`, errors)
- Optional `max_staleness` time-based safety net
- `before_refresh` / `after_refresh` callbacks
- Migration-provisioned cache tables: `activerecord_materialized:migration <View>` generates a `create_table` migration with columns/types inferred from the source relation, so the table exists at deploy time
- Boot/CI schema drift verification (`materialized:verify` / `ActiveRecord::Materialized.verify_schema!`) raises a helpful error when a view's table no longer matches its relation — never auto-alters
- Rails generators: `activerecord_materialized:install`, `activerecord_materialized:view`, `activerecord_materialized:migration`
- Rake tasks: `materialized:refresh_all`, `materialized:refresh_stale`, `materialized:rebuild`, `materialized:verify`, `materialized:warm_up`
- JOB-schema benchmark suite with multi-second analytical queries on SQLite

### Benchmark highlights (xlarge dataset, ~2M cast_info rows)

- Raw queries: 7–20 seconds
- Materialized view reads: ~0.3–0.7ms
- Speedup: 20,000–49,000×
