# Running in a distributed / high-traffic deployment

`activerecord-materialized` centralizes its coordination state in the primary database — the
cache tables and the `ar_materialized_view_metadata` row (holding `dirty`, `refreshing`,
`last_refreshed_at`, the pending-maintenance payload, …). That makes it correct across many app
servers, but two operational choices matter at scale: **which dispatcher** runs background
maintenance, and **how the periodic backstop is scheduled**.

## 1. Choose the ActiveJob dispatcher for multiple app servers

Refresh-on-write schedules maintenance through one of two dispatchers:

| Dispatcher | Coordination | Use when |
| --- | --- | --- |
| `:active_job` | Enqueues a `RefreshJob`; your job backend (Sidekiq, GoodJob, Solid Queue, …) runs it on a worker. Coalesced on the dirty edge, survives restarts, shared across the fleet. | **Any multi-process deployment.** |
| `:async` | A per-process debounced background thread. No cross-process coordination; the queue is lost on restart/deploy. | Single-process only (a script, a test, one box). |

**The default resolves automatically:** unset, `refresh_dispatcher` is `:active_job` when ActiveJob
is loaded (the usual Rails case) and `:async` otherwise. Set it explicitly to override:

```ruby
# config/initializers/activerecord_materialized.rb
ActiveRecord::Materialized.configure do |config|
  config.refresh_dispatcher = :active_job   # or :async to force the in-process thread
  config.refresh_queue_name  = :materialized_views
  config.reconcile_queue_name = :materialized_reconcile   # optional; defaults to the refresh queue
end
```

**Ensure a worker drains the queue.** With `:active_job`, refresh-on-write (and the fan-out below)
enqueue jobs onto `refresh_queue_name` / `reconcile_queue_name`; a worker must be configured to
drain them or refreshes silently never run and reads serve stale data. This is the flip side of the
auto-default: an ActiveJob-loaded app resolves to `:active_job`, so after upgrading, confirm your
worker picks up these queues (or set `config.refresh_dispatcher = :async` to keep the in-process
refresher for a single-process deployment).

If the in-process `:async` dispatcher is active while ActiveJob is available, the gem logs a one-line
boot warning — the in-process refresher is single-process-only, a hazard when more than one process
is running.

## 2. Run the periodic backstop from a single owner (fan-out)

`max_staleness` + reconciliation give a bounded-staleness safety net, but the periodic tick must be
driven from **one place**. Running `materialized:reconcile` (or `refresh_stale`) as cron on every
one of N app servers does N× the (expensive) drift verification, all contending on the same rows.

Two entry points fan the work out across your job fleet — **one job per stale view** — so many
workers share the load instead of one process doing it serially:

```ruby
ActiveRecord::Materialized.enqueue_stale_reconciles!(mode: :checksum)  # one ReconcileJob per stale view
ActiveRecord::Materialized.enqueue_stale_refreshes!                    # one RefreshJob per stale view
```

or the equivalent rake tasks:

```bash
bin/rails materialized:enqueue_reconciles   # fan out reconcile jobs
bin/rails materialized:enqueue_refreshes    # fan out refresh jobs
```

Each job re-checks the view before working (a `ReconcileJob` skips a view another worker already
made fresh), so a duplicated tick is wasteful but never incorrect — and the summary-delta path is
serialized by a row lock regardless (see [#92](https://github.com/mavrukin/activerecord-materialized/issues/92)).

**The single-owner rule.** These entry points enqueue *unconditionally*; they do not dedupe across
hosts. Run the tick from exactly one owner so the fleet enqueues each view once per interval:

- a single recurring job (Solid Queue recurring, `sidekiq-cron`, GoodJob cron), or
- a Kubernetes `CronJob` with `replicas: 1` / a dedicated utility instance, or
- a leader-elected process.

The gem intentionally ships **no scheduler and no leader election** — bring your own clock; these
entry points are the fan-out primitive it plugs into.

Without ActiveJob, `enqueue_stale_*!` raise; use the serial in-process
`ActiveRecord::Materialized.reconcile_stale!` / `Registry.refresh_stale!` instead (single-process).
