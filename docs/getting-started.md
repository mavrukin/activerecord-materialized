<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/mavrukin/activerecord-materialized/main/assets/png/lockup-horizontal-dark.png">
    <img alt="activerecord-materialized" src="https://raw.githubusercontent.com/mavrukin/activerecord-materialized/main/assets/png/lockup-horizontal.png" width="360">
  </picture>
</p>

# Getting started

A hands-on walkthrough that takes you from an empty app to a working materialized
view that refreshes itself on write. Every code block below is executed by the
test suite (`spec/docs/getting_started_tutorial_spec.rb`), so the numbers you see
here are the numbers you'll get.

By the end you will have:

- defined a view over an aggregate query,
- served correct reads **before** the view is even built (read-through),
- built the view and queried it like any ActiveRecord model,
- watched it refresh **transparently** after a write, and
- used staleness and warm-up to control freshness.

**Contents**

- [1. Install](#1-install)
- [2. Define a model and a view](#2-define-a-model-and-a-view)
- [3. Read before you build (read-through)](#3-read-before-you-build-read-through)
- [4. Build the view once](#4-build-the-view-once)
- [5. Query it like any model](#5-query-it-like-any-model)
- [6. Refresh on write](#6-refresh-on-write)
- [7. Staleness and on-demand refresh](#7-staleness-and-on-demand-refresh)
- [8. Warm up hot partitions](#8-warm-up-hot-partitions)
- [9. Production checklist](#9-production-checklist)
- [Where to go next](#where-to-go-next)

---

## 1. Install

Add the gem and install the metadata migration that tracks each view's freshness:

```ruby
# Gemfile
gem "activerecord-materialized"
```

```bash
bundle install
bin/rails generate activerecord_materialized:install
bin/rails db:migrate
```

---

## 2. Define a model and a view

Our example: a `sales` table, and a view that reports **revenue per region**. The
model is an ordinary ActiveRecord model:

```ruby
class Sale < ActiveRecord::Base
end
```

A view is a subclass of `ActiveRecord::Materialized::View` backed by its own cache
table. Its source is an `ActiveRecord::Relation` returned from `materialized_from`
— never a raw SQL string. The `QueryExpressions` helpers build portable Arel
aggregates:

```ruby
class RegionRevenue < ActiveRecord::Materialized::View
  extend ActiveRecord::Materialized::QueryExpressions

  self.table_name = "mv_region_revenue"

  materialized_from do
    sales = Sale.arel_table
    Sale.group(:region).select(
      sales[:region],
      sum_as(sales[:amount], as: :revenue),
      count_all_as(as: :sales_count)
    )
  end

  depends_on Sale            # writes to Sale schedule maintenance
  refresh_on_change :async   # refresh in the background after commit (default)
  max_staleness 6.hours      # optional time-based safety net
end
```

`depends_on Sale` does two things: it registers `Sale`'s table as a dependency of
this view, and it wires `after_*_commit` callbacks on `Sale` so committed writes
schedule maintenance automatically.

Provision the (empty) cache table with a generated migration so it exists at
deploy time:

```bash
bin/rails generate activerecord_materialized:migration RegionRevenue
bin/rails db:migrate
```

The columns and types are inferred from the source relation — here `region`
(string), `revenue` (integer), and `sales_count` (integer).

For the rest of the walkthrough, assume this seed data:

```ruby
Sale.create!(region: "west", amount: 100)
Sale.create!(region: "west", amount: 200)
Sale.create!(region: "east", amount: 50)
```

---

## 3. Read before you build (read-through)

You can query a view **before** it has ever been built. With the default
`cold_read :read_through` strategy, reads fall through to the live source query
and return correct results — a read never triggers a build:

```ruby
RegionRevenue.materialized?                       # => false
RegionRevenue.where(region: "west").pick(:revenue) # => 300  (served from the source)
RegionRevenue.materialized?                       # => false (still not built)
```

This means you can ship a view and its call sites together; nothing breaks while
the cache is still empty. (The other strategies are `:serve_stale` — return the
empty cache — and `:raise`.)

---

## 4. Build the view once

Materializing the whole view is the **only** operation that scans all the base
data, so it is explicit and guarded — it never fires implicitly from a read or a
write:

```ruby
RegionRevenue.rebuild!(confirm: true)
RegionRevenue.materialized? # => true
```

`rebuild!` runs entirely in the database (`INSERT … SELECT` over the source query,
then an atomic table swap), so the result set never crosses into Ruby memory —
safe to run against a large dataset. Do this once in a deploy/release task.

---

## 5. Query it like any model

Now reads are served straight from the cache table. The full ActiveRecord query
interface works — `where`, `order`, `pluck`, `find`, `count`, scopes:

```ruby
RegionRevenue.order(revenue: :desc).pluck(:region, :revenue)
# => [["west", 300], ["east", 50]]

RegionRevenue.where(region: "east").pick(:sales_count)
# => 1
```

No joins, no aggregation, no slow query — just a primary-key-fast lookup against a
small precomputed table.

---

## 6. Refresh on write

This is the heart of the gem. Write to a `depends_on` model and the view refreshes
itself in the background — **reads never block on it**:

```ruby
Sale.create!(region: "west", amount: 400)

RegionRevenue.dirty?                               # => true  (maintenance pending)
RegionRevenue.where(region: "west").pick(:revenue) # => 300   (previous snapshot)
```

The view is marked dirty the moment the write commits, but the cache still serves
the last good snapshot until maintenance runs. Once it does, the affected
partition reflects the change:

```ruby
# In production this happens on a background thread or job worker. In a test you
# can force it synchronously:
ActiveRecord::Materialized::AsyncRefresher.flush!

RegionRevenue.dirty?                               # => false
RegionRevenue.where(region: "west").pick(:revenue) # => 700
```

Because `revenue`/`sales_count` are **distributive** aggregates (`SUM`/`COUNT`),
the gem applies a signed delta straight to the `west` row — it does not re-read the
base rows or rebuild the table. Non-distributive views (`AVG`, `MIN`, `MAX`,
`COUNT(DISTINCT)`, joins, `HAVING`) re-aggregate only the affected partitions
instead; both paths leave every other partition untouched.

---

## 7. Staleness and on-demand refresh

`max_staleness` lets cron or a scheduler top up freshness without coupling to
writes. `refresh_if_stale!` is a no-op when the view is already fresh and refreshes
incrementally when it isn't:

```ruby
RegionRevenue.stale?            # => false
RegionRevenue.refresh_if_stale! # => nil   (nothing to do)

Sale.create!(region: "north", amount: 999)
RegionRevenue.stale?            # => true

RegionRevenue.refresh_if_stale!
RegionRevenue.where(region: "north").pick(:revenue) # => 999
```

A view is "stale" when it is dirty (a dependency changed) or when
`last_refreshed_at` is older than `max_staleness`. Drive it from a scheduled task:

```bash
bin/rails materialized:refresh_stale   # refresh only the stale views
```

---

## 8. Warm up hot partitions

A cold view materializes individual `GROUP BY` partitions on demand, but you can
pre-materialize the ones you know will be hot — before traffic arrives — with
`warm_up`:

```ruby
class RegionRevenue < ActiveRecord::Materialized::View
  # ...
  warm_up { [where(region: "west"), where(region: "east")] }
end
```

```ruby
RegionRevenue.warm_up! # materializes the west/east partitions; the rest read through
```

Run it at deploy time (or via `bin/rails materialized:warm_up`) so your most
important reads are fast immediately, while everything else stays correct via
read-through until it's touched.

---

## 9. Production checklist

- **Use ActiveJob for refresh.** Set `config.refresh_dispatcher = :active_job` so
  maintenance runs on job workers (Sidekiq, GoodJob, Solid Queue, …) rather than
  on web threads.
- **Build during deploys.** Call `rebuild!(confirm: true)` (or
  `bin/rails materialized:rebuild`) for new views as a release step — never at
  request time.
- **Index your cache columns.** Cache tables are created from query results; add
  indexes on the columns you filter and sort on.
- **Verify schema in CI.** `bin/rails materialized:verify` raises if a cache table
  has drifted from its source relation, so you catch a missing migration early.
- **Declare every dependency.** Refresh-on-write only fires for tables you list in
  `depends_on`, and only for writes that go through ActiveRecord (raw SQL writes
  bypass the commit callbacks).

```ruby
# config/initializers/activerecord_materialized.rb
ActiveRecord::Materialized.configure do |config|
  config.default_refresh_strategy   = :async
  config.default_refresh_debounce   = 30.seconds
  config.refresh_dispatcher         = :active_job
  config.refresh_queue_name         = :materialized_views
  config.default_max_staleness      = 12.hours
  config.default_cold_read_strategy = :read_through
end
```

---

## Where to go next

- The [README](../README.md) — architecture diagram, the full API reference, the
  research background, and benchmark results.
- The runnable [`demo/`](../demo/) Rails app — compare raw vs. materialized timings
  side by side and watch a view go stale and catch up.
- [`benchmark/DATA.md`](../benchmark/DATA.md) — dataset scales and how the
  benchmark suite is wired up.
