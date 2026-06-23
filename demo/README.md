# activerecord-materialized — interactive demo

A tiny Rails app that lets you *feel* the gem: run the same analytical query the
slow way and through a materialized view **side by side**, pick how big a dataset
to run against, mutate the underlying data, and watch a view go stale and catch
back up.

It depends on the gem via `path: ".."`, exactly the way a real application would
depend on a released version, and reads the JOB benchmark databases that ship
with the repository.

## Setup

From the **repository root**, generate one or more datasets. The demo discovers
every `benchmark/fixtures/*.sqlite` file and lets you switch between them, so
generate a couple of scales to feel the difference:

```bash
bundle install
JOB_DB=benchmark/fixtures/job.small.sqlite  JOB_SCALE=small  bundle exec rake benchmark:setup
JOB_DB=benchmark/fixtures/job.sqlite        JOB_SCALE=medium bundle exec rake benchmark:setup
# Bigger = far slower raw queries (and the most convincing demo):
JOB_DB=benchmark/fixtures/job.xlarge.sqlite JOB_SCALE=xlarge bundle exec rake benchmark:setup   # ~2M rows
```

Then boot the demo:

```bash
cd demo
bundle install
bin/rails server          # http://localhost:3000
```

## The page

- **Dataset switcher** (top) — pick which generated database to run against; the
  app reconnects in place and row counts update. It lists every standard scale
  with its rough speedup; ones you haven't generated yet are shown disabled with
  a one-line command to create them. The bigger the dataset, the more dramatic
  the win (medium ≈ 50×, xlarge ≈ thousands×).
- **Three scenarios** of increasing cost, each self-contained:

  | Scenario | Complexity | Depends on `cast_info`? |
  |----------|------------|--------------------------|
  | Production notes | Simple | no |
  | Gender pairing stats | Complex | **yes** |
  | Person–movie network | Very complex | yes |

  Expand **Show the query** to see the actual SQL the view materializes.

Each scenario has these actions, and the result renders **inline, right under the
scenario** (no jumping to the top of the page):

- **Compare raw vs view** — runs the query both ways and shows them side by side:
  timing, row count, and the **actual result rows**, plus whether they agree. On a
  cold view this transparently reads *through* to the source; once built it reads
  from the cache.
- **Build / refresh** — materializes (or re-materializes) the cache table; the
  one-time bootstrap cost is shown explicitly.
- **Insert cast rows** — writes rows to `cast_info`, which the gem's `after_commit`
  hooks turn into a "dirty" marker on every dependent view.
- **Reset to cold** — drops the cache table so you can replay the cold-read story.

## A guided tour

This walks the four cases the gem is built for:

1. **No prior MV → read-through.** On a fresh (or **Reset to cold**) scenario,
   click **Compare**. The view isn't built, so it reads *through* to the source —
   correct results, still slow. Both columns match.
2. **Raw vs. materialized.** Click **Build / refresh**, then **Compare** again.
   Same answer, now served from the cache table — orders of magnitude faster (the
   gap widens dramatically on the larger datasets).
3. **Transparent updates.** Click **Insert cast rows**, then **Compare**: the raw
   query reflects the new rows immediately while the cache still holds the old
   value (the card shows **Stale**), and the two result tables now differ. Click
   **Build / refresh** and **Compare** once more — the view has caught up.
4. **Real results, not just timings.** Every comparison shows the actual rows
   returned by both paths, the row counts, the timings, and the query's SQL.

## Notes

- The demo sets each view's refresh strategy to `:manual` so *you* drive the
  refresh and can watch the stale → fresh transition. Production apps typically
  keep the default `:async` strategy, which refreshes automatically in the
  background after writes commit.
- Switching datasets reconnects ActiveRecord at runtime and resets the gem's
  per-database schema/metadata caches; each database keeps its own cache tables.
- Everything here lives under `demo/` and is excluded from the published gem.
