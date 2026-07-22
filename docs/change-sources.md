# Change sources

Callbacks are the default change source — declaring `depends_on` wires ActiveRecord commit hooks that publish every in-app write to a view. External, bulk, raw-SQL, and CDC writes bypass those callbacks, so they feed the view through the public ingestion API instead.

A **change source** is whatever tells a view its dependency data changed. The
built-in default is ActiveRecord commit callbacks: declaring `depends_on` installs
`after_*_commit` hooks on the model, and every committed write is published to the
view. Callbacks are the right default for in-app writes, but they only observe
writes that go through ActiveRecord — bulk paths (`insert_all` / `update_all`), raw
SQL, and writes from other processes bypass them. For those, drive maintenance
through the public ingestion API from your own change source.

### The ingestion API

Two module-level entry points, callable from anywhere — a job, a rake task, an
external consumer:

```ruby
# Fine-grained: publish a specific committed write. Drives the externally-fed
# views (change_source :none) on that table; a callback-driven view is left to its
# own commit callbacks, so it is never maintained twice.
ActiveRecord::Materialized.publish_write_change!(
  ActiveRecord::Materialized::WriteChange.from_record(line_item, :create)
)

# Coarse: "something in these tables changed" — enqueues a full recompute for every
# dependent view and schedules it. Use when you cannot describe the individual
# write, or to recover a callback-driven view after a callback-skipping bulk load
# (insert_all/update_all). Idempotent, so safe to call repeatedly.
ActiveRecord::Materialized.mark_dirty_for_tables!(["line_items"])
```

### Running callback-free

To drive a view entirely from an external source, turn off automatic callback
installation — globally or per view. `depends_on` still declares the dependency
tables (used for scoping and metadata); only the commit-callback wiring is skipped.

```ruby
# Globally, in the initializer:
ActiveRecord::Materialized.configure { |c| c.default_change_source = :none }

# Or per view — declare change_source :none before depends_on (or rely on the
# global default) so no commit callbacks are installed for it:
class SalesSummary < ActiveRecord::Materialized::View
  materialized_from { ... }
  change_source :none         # fed by an external adapter
  depends_on :line_items      # still declared for scoping and metadata
end
```

(Opting back in with `change_source :callbacks` re-installs callbacks for
already-declared dependencies, so it works in either order.)

Each view is fed by exactly one source, and the engine enforces it: a committed
write reaches only the callback-driven views on the table, and a
`publish_write_change!` call reaches only the externally-fed ones. So callback-driven
and externally-fed views coexist safely — no view is maintained twice — even when
they share a dependency table.

### Writing a custom adapter

An adapter's only job is to observe changes and call the ingestion API. The engine
expects, and provides:

- **Idempotency / at-least-once** — an externally-fed view recomputes its affected
  partitions from the source (never the additive summary-delta path), so
  redelivering the same change converges instead of double-counting. At-least-once
  delivery is fine.
- **Out-of-order tolerance** — partitions are recomputed from the source, so events
  need not arrive in commit order.
- **Optional key tuples** — a `WriteChange` carrying the `GROUP BY` columns scopes
  the recompute to the affected partitions; without them it widens to a full
  recompute (always correct, just less efficient), and `mark_dirty_for_tables!` is
  the fully coarse form.

The built-in callback tracker (`DependencyTrackable`) is itself implemented on top
of `publish_write_change!` — a custom adapter is no different.

### Driving maintenance from CDC / an external change stream

Model callbacks only observe writes that go through the app's ActiveRecord layer.
The mechanism that captures *every* committed change — regardless of who wrote it
(app, raw SQL, bulk loaders, other services) — is database **Change Data Capture**:
consuming the binlog / WAL via a Debezium- or Maxwell-style pipeline. `ingest_change`
is the descriptor-oriented entry point for wiring such a stream to the engine,
without the gem depending on any specific CDC tool. Views fed this way declare
`change_source :none`.

CDC is **one option, not a requirement** — and the heaviest. It's the last rung of the layered
[change-source ladder](out-of-band-writes.md#the-layers-of-defense): in-app callbacks (the
default) → the ingestion API → the [trigger/outbox adapter](#capturing-out-of-band-writes-with-database-triggers)
→ CDC → reconciliation underneath as the backstop. Reach for CDC only when you already run a
binlog/WAL pipeline or need org-wide completeness; most apps never do. And nothing in the gem depends
on Debezium or any specific CDC tool — `ingest_change` takes plain descriptors, so Maxwell, Kafka
Connect, a custom consumer, or the built-in trigger/outbox all normalize to the same call.

```ruby
# A change-stream consumer relays each committed change. Normalize your stream's
# event shape to this call; nothing here is tied to a particular CDC system.
consumer.each do |event|
  ActiveRecord::Materialized.ingest_change(
    table:          event.fetch("table"),
    operation:      event.fetch("op"),   # :create / :update / :destroy
    key_attributes: event["key"],        # the GROUP BY columns of the row, if known
    before:         event["before"],     # optional pre-image  (:update / :destroy)
    after:          event["after"]       # optional post-image (:create / :update)
  )
end
```

**Delivery semantics** the engine relies on (so a real-world stream just works):

- **At-least-once is fine.** An externally-fed view recomputes its affected
  partitions, so a redelivered change converges — it never double-counts.
- **Out-of-order is tolerable.** Partitions are recomputed from the source, so
  events need not arrive in commit order.
- **Key tuples are optional.** `key_attributes` (or a full `before`/`after` image)
  scopes the recompute to the affected partitions; omit them and the change widens
  to a full recompute — always correct, just less efficient. This is the knob to
  reach for when your stream can't reliably supply the `GROUP BY` columns. A
  partition-moving `:update` needs both sides (full `before`+`after`, or
  `key_attributes`); a lone after-image can't identify the old partition, so it
  safely widens rather than under-scoping (relevant for minimal-image binlogs).
- **Watermarks are optional.** Pass `source_ts:` (a monotonic per-partition value —
  a Debezium `source.ts_ms`, a Kafka offset) and the engine records the max applied
  watermark per partition: a redelivered or out-of-order change whose watermark is
  *strictly older* than the partition's applied watermark is skipped as provably-stale
  (a distinct change sharing a coarse timestamp — e.g. a second-granular binlog
  `ts_ms` — still applies, so a real write is never dropped; an optimization over
  always-recompute — best-effort and backed by reconciliation, never a substitute for
  it), and a view's freshness is observable via `SalesSummary.source_watermark` (the
  oldest applied partition watermark; subtract from your source clock for lag). Omit it
  and behavior is unchanged.

**Decoding a log-based CDC envelope.** A log-based CDC platform (Debezium / Maxwell /
Kafka Connect, reading the MySQL binlog or Postgres WAL) emits a change envelope that
maps directly onto this call: `op` `c`/`u`/`d`/`r` → `:create`/`:update`/`:destroy`
(a snapshot `r` → `:create`), the `before`/`after` row images → `before:`/`after:`, and
`source.table` → `table:`. Capturing the **old-image** partition key on an update or
delete requires **full row images** — MySQL `binlog-row-image=FULL` and Postgres
`REPLICA IDENTITY FULL`. With only the primary key in the before-image, a
partition-moving update can't identify the old partition, so that partition is
under-maintained until [reconciliation](reconciliation.md#bounded-staleness-and-self-healing) heals it —
configure full images for correct partition-moving updates. This path is
integration-tested by decoding a real `test_decoding` logical
slot (Postgres) and a real ROW binlog (MySQL) and asserting the view converges — so the
ingestion API is verified against what an actual CDC consumer emits, not a synthesized
descriptor (see [integration testing](integration-testing.md)).

The Debezium envelope shape is common enough to warrant a helper, so — **optionally** — rather than
hand-write that mapping you can pass the decoded envelope straight to `ingest_debezium_change`, which
does it for you (op → operation, `before`/`after`, `source.table`, and `source.ts_ms` → `source_ts`
(the watermark above) while unwrapping a nested `payload`) and no-ops a `nil` tombstone:

```ruby
consumer.each do |event|
  ActiveRecord::Materialized.ingest_debezium_change(event)
rescue => e
  # Isolate a bad event and keep consuming (log it / route to a DLQ) rather than poison-pilling the
  # stream. A non-row op like TRUNCATE ("t") raises here — recompute those with
  # ActiveRecord::Materialized.mark_dirty_for_tables!(["line_items"]).
  report(e)
end
```

A Maxwell, Kafka Connect, or custom stream needs no such helper — normalize its event shape to
`ingest_change` in the couple of lines shown above. `ingest_debezium_change` is pure opt-in sugar over
that tool-agnostic call, not a dependency: the gem ships no Debezium or Kafka library, and Debezium is
not a change source you configure (the sources are `:callbacks` and `:none`) — just one way to produce
descriptors for the `:none` path.

CDC composes with callbacks (use callbacks for in-app writes and CDC for the write
paths they miss) as long as each view has a single source: give CDC-fed views
`change_source :none`.

### Capturing out-of-band writes with database triggers

When you can't hook the write in code (a DBA's ad-hoc SQL, another service writing
the same table) but don't want to operate a full CDC pipeline, the built-in
**trigger/outbox adapter** captures *every* write to a table database-side and relays
it into scoped maintenance — no external infrastructure:

```bash
bin/rails generate activerecord_materialized:outbox line_items category region
bin/rails db:migrate   # installs AFTER INSERT/UPDATE/DELETE triggers (adapter-correct DDL)
```

```ruby
# Relay captured writes on a schedule (cron / recurring job / poller).
ActiveRecord::Materialized.drain_write_outbox!
```

Triggers append the changed `GROUP BY` keys to an outbox table; `drain_write_outbox!`
relays them through `ingest_change`, so an out-of-band write maintains exactly the
partitions it touched. The triggers fire on *every* write to the table, so the fed view
is `change_source :none` (a single source — not mixed with callbacks). See
**[detecting out-of-band writes](out-of-band-writes.md)**
for the full layered defense (callbacks → ingestion API → triggers → CDC →
reconciliation) and when to choose each.

---

[← Back to the README](../README.md)
