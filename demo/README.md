# activerecord-materialized — interactive demo

A tiny Rails app that lets you *feel* the gem: run the same analytical query the
slow way and through a materialized view, mutate the underlying data, and watch
the view go stale and then catch back up.

It depends on the gem via `path: ".."`, exactly the way a real application would
depend on a released version, and reads the JOB benchmark database that ships
with the repository.

## Setup

From the **repository root**, generate a dataset (any scale works; bigger scales
make the raw queries dramatically slower):

```bash
bundle install
bundle exec rake benchmark:setup              # medium (~180k cast_info rows)
# JOB_SCALE=xlarge bundle exec rake benchmark:setup   # ~2M rows; seconds-long raw queries
```

Then boot the demo:

```bash
cd demo
bundle install
bin/rails server          # http://localhost:3000
```

The demo reads `../benchmark/fixtures/job.sqlite` by default. Point it elsewhere
with `JOB_DB=/path/to/job.sqlite bin/rails server`.

## What you'll see

The page lists three scenarios of increasing cost:

| Scenario | Complexity | Depends on `cast_info`? |
|----------|------------|--------------------------|
| Production notes | Simple | no |
| Gender pairing stats | Complex | **yes** |
| Person–movie network | Very complex | yes |

For each scenario you get four actions:

- **Run raw query** — executes the source `ActiveRecord::Relation` directly. This
  is what your app does today: correct, always current, and slow.
- **Run materialized view** — reads the precomputed cache table. Sub-millisecond,
  regardless of dataset size.
- **Build / refresh** — materializes (or re-materializes) the cache table. The
  first build is the one-time bootstrap cost; the timing is shown so you can see
  it explicitly rather than having it hide inside a user's first read.
- **Insert a cast member** — writes a row to `cast_info`, which the gem's
  `after_commit` hooks turn into a "dirty" marker on every dependent view.

## A guided tour

1. Pick **Gender pairing stats** and click **Run raw query** — note the time.
2. Click **Build / refresh** to materialize it (watch the bootstrap cost).
3. Click **Run materialized view** — same answer, a fraction of the time.
4. Click **Insert a cast member**. The card flips to **Stale — needs refresh**.
5. **Run raw query** again — the raw number already reflects the new row.
6. **Run materialized view** again — it still shows the *old* number: the cache
   is intentionally stale until refreshed (eventual consistency).
7. Click **Build / refresh**, then **Run materialized view** — it has caught up,
   and reads are fast again.

## Notes

- The demo sets each view's refresh strategy to `:manual` so *you* drive the
  refresh and can watch the stale → fresh transition. Production apps typically
  keep the default `:async` strategy, which refreshes automatically in the
  background after writes commit.
- Everything here lives under `demo/` and is excluded from the published gem.
