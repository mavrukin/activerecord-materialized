# Detecting out-of-band writes

A materialized view is only as fresh as its change source. The default source — ActiveRecord
commit callbacks on `depends_on` models — sees a write **only when it goes through the app's
ActiveRecord layer**. Plenty of real writes don't:

- **Raw SQL** from a `rails dbconsole`/`psql`/`mysql` session, or `execute("UPDATE …")`.
- **Bulk operations** that skip callbacks: `insert_all`/`upsert_all`/`update_all`/`delete_all`, a
  `LOAD DATA`/`COPY` import, a data-migration backfill.
- **Another service** writing the same database directly.

Left unobserved, such a write leaves the affected partition wrong until something else corrects it.
This guide covers the **layers of defense** against that, and the built-in **trigger/outbox
adapter** — a database-native way to capture *every* write to a table without standing up an
external CDC pipeline.

## The layers of defense

Pick the least amount of machinery that closes the gap for *your* write paths. Each layer is
independent; most deployments combine two or three.

| Layer | Captures | Cost | Use when |
| --- | --- | --- | --- |
| **Callbacks** (default) | In-app ActiveRecord writes | None | The app is the only writer and never bulk-writes |
| **Ingestion API** (`ingest_change`) | Any write you can hook *in code* | A call per change | You control the out-of-band path (a bulk loader, a known raw-SQL job) |
| **Trigger/outbox** (this guide) | *Every* write to a table, incl. raw SQL & other services | Per-write trigger + a drain loop | One database, a few tables, no CDC platform |
| **CDC** (binlog/WAL) | Every write, across many tables/services | A streaming pipeline (Debezium/Maxwell) | Org-wide completeness; you already run CDC |
| **Reconciliation** (backstop) | *Whatever the above missed* | One drift check per stale view per tick | Always — it bounds the damage of any missed write |

The first four are **completeness** layers (catch the write when it happens); the last is a
**time-bounded backstop** (find and repair drift on a schedule). They compose: use callbacks for
in-app writes, a completeness layer for the paths callbacks miss, and reconciliation underneath so
*any* residual miss self-heals within a bounded window.

- Ingestion API — see [Driving maintenance from CDC / an external change stream](change-sources.md#driving-maintenance-from-cdc--an-external-change-stream).
- Reconciliation — see [Bounded staleness and self-healing](reconciliation.md#bounded-staleness-and-self-healing).

## When to reach for the trigger/outbox adapter

It occupies the middle ground between "hook it in code" and "run a CDC platform":

- **vs. the ingestion API** — you *can't* hook the write in code (a DBA runs ad-hoc SQL; another
  service writes the table). Triggers fire regardless of who writes.
- **vs. CDC** — you don't want to operate a binlog/WAL streaming pipeline for one database and a
  handful of tables. Triggers need no external infrastructure — just the database you already have.

Trade-offs to weigh: triggers add a small write-time cost to the watched table, they are DDL you
install and version like any schema change, and the outbox must be drained by a poller or job. If
you already run CDC, or you need completeness across many tables and services, prefer CDC.

## How it works

```
raw/bulk/other-service write to line_items
        │
        ▼
  AFTER INSERT/UPDATE/DELETE trigger        ← installed by the generator's migration
        │  captures only the GROUP BY key columns, as JSON
        ▼
  ar_materialized_view_write_outbox         ← durable queue (source_table, operation, key_before, key_after)
        │
        ▼
  ActiveRecord::Materialized.drain_write_outbox!   ← run from a poller / cron / job
        │  relays each row via ingest_change(before:, after:)
        ▼
  scoped maintenance of the affected partition(s)
```

Capture is **scoped**: the trigger records only the configured key columns (the view's `GROUP BY`
columns), not the whole row. That is exactly what
[`ingest_change`](change-sources.md#driving-maintenance-from-cdc--an-external-change-stream) needs to
scope maintenance to the affected partition(s):

- an **insert** records the new-image keys (`key_after`) → the new partition;
- a **delete** records the old-image keys (`key_before`) → the old partition;
- an **update** records **both** → so an update that moves a row between partitions maintains the
  old partition *and* the new one.

If you capture no key columns (an un-grouped, whole-table aggregate), each write relays an empty
image, which correctly widens to a full recompute of that view.

## Usage

### 1. Install triggers on the dependency table

```bash
bin/rails generate activerecord_materialized:outbox line_items category region
bin/rails db:migrate
```

The trailing arguments are the `GROUP BY` key columns to capture. The generated migration calls
`WriteOutbox.install_triggers!`, which emits the correct trigger DDL for the connection's adapter
(SQLite / MySQL / PostgreSQL) **at migrate time** and lazily provisions the outbox table on first
install. The view itself is fed like any externally-driven view — declare `change_source :none`, so
the outbox is its [single change source](#the-outbox-is-a-single-change-source).

The migration is reversible: `down` runs `WriteOutbox.uninstall_triggers!`, dropping the triggers
(and, on PostgreSQL, the trigger function).

### 2. Drain the outbox

Relay captured writes into view maintenance on a schedule — from cron, a recurring ActiveJob, or a
poller loop:

```ruby
# Relay all pending rows (or pass limit: to bound a batch), returning the count relayed.
ActiveRecord::Materialized.drain_write_outbox!

# Drain in bounded batches until empty — friendlier to a busy table.
loop { break if ActiveRecord::Materialized.drain_write_outbox!(limit: 500).zero? }
```

Draining has three properties worth relying on:

- **At-least-once.** A row is deleted only after its relay succeeds, so a crash mid-drain re-relays
  the not-yet-deleted rows next pass — safe, since `ingest_change` is convergent (scoped recompute is
  idempotent), so a redelivered change never double-counts.
- **Bounded memory.** Rows are relayed in internal batches, so a large backlog (a bulk backfill, or a
  window when the drain wasn't running) drains without loading the whole outbox at once — pass
  `limit:` to additionally cap the rows attempted per call.
- **Per-row isolation.** A relay that raises (e.g. a view whose scoped recompute fails) leaves only
  that row in the outbox for retry and is skipped for the rest of the pass, so one un-relayable row
  can't block the writes queued behind it. The failing view records its own error on its metadata,
  and a warning is logged; the row is retried on the next drain and clears once the view is fixed.

`drain_write_outbox!` is a no-op before any triggers are installed, so a scheduled drain is safe to
run even if the `outbox` migration hasn't been applied yet. The drain interval is the freshness knob:
it bounds how long an out-of-band write waits before the view reflects it.

Run the drain from a **single** worker (one cron/recurring job/leader). Concurrent drainers are
*safe* — `ingest_change` is idempotent, so an overlapping relay of the same row just recomputes a
partition twice — but they do duplicate maintenance work; the gem ships no leader election.

### The outbox is a single change source

The outbox is a change source in its own right, exactly like [CDC](change-sources.md#driving-maintenance-from-cdc--an-external-change-stream):
`drain_write_outbox!` relays through `ingest_change`, which delivers **only** to views declared
`change_source :none` (the engine ties each view to a single source so an additive delta is never
applied twice). So a view fed by the outbox must be `change_source :none` — you cannot keep callbacks
on it and add triggers "for the rest"; the drained writes would be routed away from a callback-backed
view and silently dropped.

That single source is not a limitation here, because the triggers fire on **every** write to the
table — in-app ActiveRecord writes included. A `change_source :none` view with triggers installed is
therefore maintained for all writes (in-app and out-of-band) through the one drain path; you don't
also need callbacks.

## Cross-engine notes

`install_triggers!` is portable; the dialect differences are handled for you:

- **PostgreSQL** — one trigger function (branching on `TG_OP`) fired by a single
  `AFTER INSERT OR UPDATE OR DELETE` trigger; keys built with `jsonb_build_object(...)::text`.
- **MySQL / MariaDB** — one single-statement trigger per operation; keys built with `JSON_OBJECT`.
- **SQLite** — one `BEGIN … END` trigger per operation; keys built with `json_object`.

Trigger and function identifiers are named `<table>_arm_wob[_ins|_upd|_del|_fn]`; keep source table
names within your database's identifier-length limit (63 chars on PostgreSQL, 64 on MySQL) so the
derived names don't collide.

## Operational notes

- **Monitor outbox depth.** A growing `ar_materialized_view_write_outbox` means the drain isn't
  keeping up (or isn't running). Alert on row count / oldest `created_at`.
- **Reconciliation still underneath.** Triggers close the raw-write gap, but keep reconciliation
  running as the backstop for anything the outbox itself can't cover (e.g. a `TRUNCATE`, which fires
  no per-row trigger, or writes to a table before triggers were installed).
- **Drain on the primary.** The drain reads and deletes outbox rows and drives maintenance; run it
  where maintenance runs (see [writer/replica routing](distributed-deployment.md)).
