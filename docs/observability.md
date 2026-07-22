# Observability

The gem emits `ActiveSupport::Notifications` events at its read, refresh, and maintenance lifecycle points, so you can wire freshness and behavior SLIs to any telemetry backend without the gem depending on a specific vendor.

The gem instruments its read, refresh, and maintenance lifecycle points with
[`ActiveSupport::Notifications`](https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html)
events. The event names and payload keys below are a stable contract — subscribe
to wire freshness and behavior SLIs to any APM / StatsD / OpenTelemetry backend
without the gem taking a dependency on a specific telemetry vendor.

| Event | When | Payload |
|-------|------|---------|
| `read.active_record_materialized` | Once per routed read (`where`, `find`, `count`, …) | `:view`, `:source` (`:cache`, `:read_through`, `:serve_stale`, `:raise`), `:staleness` (seconds since last refresh, or `nil`) |
| `refresh.active_record_materialized` | Once per `refresh!` / `rebuild!`, timed | `:view`, `:operation` (`:incremental`/`:rebuild`), `:mode` (`:summary_delta`/`:scoped_recompute`/`:full`), `:partition_count` (partitions recomputed, `nil` for a full pass), `:row_count`, `:skipped`, and on failure the standard `:exception`/`:exception_object` |
| `maintenance.active_record_materialized` | Once per dependency write that records pending maintenance | `:view`, `:table`, `:operation` (`:create`/`:update`/`:destroy`), `:path` (`:summary_delta`/`:scoped_recompute`), `:scope` (`:scoped`, or `:full` when the write **widened to a full recompute**), `:partition_count` (distinct partitions scoped, `0` on a widen) |
| `reconcile.active_record_materialized` | Once per `reconcile!` / `reconcile_stale!` run per view | `:view`, `:mode` (drift-check depth), `:repaired_partition_count` (partitions repaired with scoped maintenance), `:deferred` (`true` when a concurrent refresh deferred the run to the next tick) |

A read served with `source: :read_through` means the view was cold and the query
fell through to the source. A maintenance event with `scope: :full` means the
write's partition key could not be derived and maintenance widened to a full
recompute — a high widen rate is the signal to scope it (see the join-keyed
resolver) or to investigate a missing change source.

### Example subscriber

```ruby
# config/initializers/materialized_metrics.rb
ActiveSupport::Notifications.subscribe("read.active_record_materialized") do |event|
  payload = event.payload
  StatsD.increment("mv.read", tags: ["view:#{payload[:view]}", "source:#{payload[:source]}"])
  StatsD.gauge("mv.read.staleness", payload[:staleness], tags: ["view:#{payload[:view]}"]) if payload[:staleness]
end

ActiveSupport::Notifications.subscribe("refresh.active_record_materialized") do |event|
  payload = event.payload
  StatsD.distribution("mv.refresh.duration", event.duration, tags: ["view:#{payload[:view]}", "mode:#{payload[:mode]}"])
  StatsD.increment("mv.refresh.error", tags: ["view:#{payload[:view]}"]) if payload[:exception]
end

ActiveSupport::Notifications.subscribe("maintenance.active_record_materialized") do |event|
  payload = event.payload
  StatsD.increment("mv.maintenance.widen", tags: ["view:#{payload[:view]}"]) if payload[:scope] == :full
end
```

The constants `ActiveRecord::Materialized::Instrumentation::READ`, `REFRESH`,
`MAINTENANCE`, and `RECONCILE` hold the event-name strings if you prefer referencing
them over string literals. Read events are emitted only while a subscriber is attached, so
there is no staleness-lookup cost on the read path when nobody is listening.

---

[← Back to the README](../README.md)
