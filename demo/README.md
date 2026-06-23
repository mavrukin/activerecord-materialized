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
- **Insert cast rows** — writes rows to `cast_info`. The gem's `after_commit`
  hooks mark every dependent view out of sync and an in-process background refresh
  brings it back up to date on its own. The status pill updates live
  (**out of sync → syncing → up to date**) as the page polls `/status`.
- **Reset to cold** — drops the cache table so you can replay the cold-read story.

## A guided tour

This walks the four cases the gem is built for:

1. **No prior MV → read-through.** On a fresh (or **Reset to cold**) scenario,
   click **Compare**. The view isn't built, so it reads *through* to the source —
   correct results, still slow. Both columns match.
2. **Raw vs. materialized.** Click **Build / refresh**, then **Compare** again.
   Same answer, now served from the cache table — orders of magnitude faster (the
   gap widens dramatically on the larger datasets).
3. **Transparent, self-healing updates.** Click **Insert cast rows**. The view's
   status flips to **out of sync** and then, a moment later, back to **up to date**
   on its own — a background refresh ran with no action from you. **Compare**
   right after the insert to catch the cache mid-recovery (the result tables
   differ), then again once it's up to date (they match).
4. **Real results, not just timings.** Every comparison shows the actual rows
   returned by both paths, the row counts, the timings, and the query's SQL.

## Notes

- The demo uses the gem's default `:async` refresh strategy (with a short
  debounce) so writes refresh the view automatically in the background, exactly
  as a production app would. The page polls `/status` to surface the
  out-of-sync → up-to-date transition; SQLite runs in WAL mode so those reads
  aren't blocked while a refresh holds the write lock.
- Switching datasets reconnects ActiveRecord at runtime and resets the gem's
  per-database schema/metadata caches; each database keeps its own cache tables.
- Everything here lives under `demo/` and is excluded from the published gem.
