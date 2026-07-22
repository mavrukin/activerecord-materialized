# API reference

The complete surface area of `activerecord-materialized`: the global configuration block, class methods, DSL macros, `QueryExpressions` helpers, and rake tasks.

## Configuration

```ruby
# config/initializers/activerecord_materialized.rb
ActiveRecord::Materialized.configure do |config|
  config.default_refresh_strategy = :async
  config.default_refresh_debounce = 30.seconds
  config.refresh_dispatcher = :active_job   # :async for in-process thread
  config.refresh_queue_name = :materialized_views
  config.default_max_staleness = 12.hours
  config.default_cold_read_strategy = :read_through  # :serve_stale or :raise
  config.default_change_source = :callbacks          # :none to drive views from a custom source
  config.atomic_swap_refresh = true
  config.max_tracked_partitions = 1_000             # collapse to a full recompute past this
  config.metadata_table_name = "ar_materialized_view_metadata"

  # Writer/replica topology (see the distributed-deployment guide) — all default to off:
  config.maintenance_role = :writing   # route refresh/reconcile/rebuild to the primary
  config.verification_role = :reading  # offload DataVerifier reads to a replica
  config.replica_lag = 0               # replication-lag budget folded into staleness
end
```

---

### Class methods

| Method | Description |
|--------|-------------|
| `rebuild!(confirm: true)` | **Explicit** full materialization via in-database `INSERT … SELECT` (the only full-scan path; never fires implicitly, never buffers rows in Ruby) |
| `warm_up!` | Materialize the configured `warm_up` partitions ahead of traffic |
| `refresh!` | Incremental maintenance only (no-op on an unbuilt view); never rebuilds |
| `refresh_if_stale!` | Incremental maintenance when materialized and stale |
| `reconcile!(mode:, sample:)` | Verify contents against the source and repair drift with scoped maintenance (never a rebuild); see [self-healing](reconciliation.md#bounded-staleness-and-self-healing) |
| `materialized?` | Whether the view has been built (warm) and reads serve from the cache |
| `dirty?` | Whether a dependency change is pending maintenance |
| `stale?` | Whether view is dirty or exceeds `max_staleness` |
| `last_refreshed_at` | Timestamp of last successful refresh |
| `refreshing?` | Whether a refresh is in progress |
| `resolved_source` | The current `ActiveRecord::Relation` used for refresh |

### DSL

| Macro | Description |
|-------|-------------|
| `materialized_from { relation }` | Block returning the source `ActiveRecord::Relation` |
| `depends_on(*models_or_tables)` | Register dependencies; writes trigger refresh |
| `refresh_on_change(strategy)` | `:async`, `:immediate`, or `:manual` |
| `refresh_debounce(duration)` | Coalesce rapid writes before refreshing |
| `refresh_mode(mode)` | `:incremental` (default) or `:full` |
| `cold_read(strategy)` | Read behavior before the view is built: `:read_through` (default), `:serve_stale`, or `:raise` |
| `change_source(source)` | Where this view's changes come from: `:callbacks` (default) or `:none` (fed via the ingestion API — see [Change sources](change-sources.md)) |
| `warm_up { [relations] }` | Representative queries whose partitions `warm_up!` materializes ahead of traffic |
| `incremental_from { relation }` | Optional override for scoped maintenance relation |
| `incremental_keys(*columns)` | Optional override for inferred `GROUP BY` keys |
| `partition_key_for(table) { \|change\| ... }` | Resolve a write on a joined/leaf `table` to the affected partition key(s), so maintenance scopes instead of widening |
| `max_staleness(duration)` | Optional time-based safety refresh via rake/cron |
| `before_refresh` / `after_refresh` | Refresh lifecycle callbacks |

### QueryExpressions

Include or extend `ActiveRecord::Materialized::QueryExpressions` when defining aggregations:

| Helper | Arel equivalent |
|--------|-----------------|
| `sum_as(attr, as: :name)` | `SUM(...)` |
| `avg_as(attr, as: :name)` | `AVG(...)` |
| `count_as(attr, as: :name)` | `COUNT(...)` |
| `count_distinct_as(attr, as: :name)` | `COUNT(DISTINCT ...)` |
| `count_all_as(as: :name)` | `COUNT(*)` |
| `min_as` / `max_as` | `MIN` / `MAX` |

### Rake tasks

```bash
bin/rails materialized:refresh_all     # incremental maintenance pass
bin/rails materialized:refresh_stale
bin/rails materialized:rebuild         # intentional full materialization (in-DB INSERT … SELECT)
bin/rails materialized:verify          # raise on cache-table schema drift
bin/rails materialized:audit           # raise on data drift (contents vs. source)
bin/rails materialized:reconcile       # verify stale views and repair drift (scoped); for cron/ActiveJob
bin/rails materialized:enqueue_refreshes    # fan out: one RefreshJob per stale view (run from one owner)
bin/rails materialized:enqueue_reconciles   # fan out: one ReconcileJob per stale view (run from one owner)
bin/rails materialized:warm_up         # materialize configured warm_up partitions
```

For hundreds of app servers, use the `enqueue_*` fan-out tasks from a single scheduled owner instead of running `reconcile`/`refresh_stale` as cron on every box — see [distributed deployment](distributed-deployment.md).

---

[← Back to the README](../README.md)
