# Join Order Benchmark (JOB) Data

This gem ships a **synthetic JOB-schema dataset** for local benchmarking without requiring a MySQL/PostgreSQL instance. For production-like multi-second query times on SQLite, use the full JOB dataset.

## Synthetic data (included)

```bash
# medium (default) — fast CI-friendly runs
bundle exec rake benchmark:setup

# large — heavier joins
JOB_SCALE=large bundle exec rake benchmark:setup

# xlarge — multi-second raw queries on most hardware
JOB_SCALE=xlarge bundle exec rake benchmark:setup

# stress — 8M cast_info rows; use when xlarge is still too fast
JOB_SCALE=stress bundle exec rake benchmark:setup
```

## Full JOB dataset (recommended for realistic slow queries)

The [Join Order Benchmark](https://github.com/gregrahn/join-order-benchmark) uses a normalized IMDB subset designed to stress query optimizers. On SQLite, many JOB queries take **seconds to minutes**.

1. Download the CSV tarball (non-commercial research use):

   https://event.cwi.nl/da/job/imdb.tgz

2. Extract the 21 CSV files.

3. Create schema and indexes from this repository:

   - `benchmark/fixtures/job_schema.sql`
   - `benchmark/fixtures/job_indexes.sql`

4. Import into SQLite and run `ANALYZE`.

5. Point benchmarks at your database:

   ```bash
   JOB_DB=/path/to/job.sqlite bundle exec rake benchmark
   ```

## Slow queries (seconds-scale)

On the `xlarge` synthetic dataset, these views consistently run in the **1–5 second** range on SQLite:

| View | Typical raw time |
|------|------------------|
| `GenderPairingStatsView` | ~2.7s |
| `CompanyMovieCrossView` | ~2.2s |
| `PersonMovieNetworkView` | ~4.5s |

```bash
JOB_SCALE=xlarge bundle exec rake benchmark:setup   # required for benchmark:slow
bundle exec rake benchmark:slow
```

`benchmark:slow` refuses to run on databases smaller than xlarge (checks `cast_info` row count).
If xlarge is still fast on your machine, use `JOB_SCALE=stress`.

## Update simulation (incremental maintenance)

Verify the full write → maintain → read workflow:

```bash
bundle exec rake benchmark:verify_updates
```

The script:

1. **Bootstraps** the cache table once if missing (`CREATE TABLE AS` + atomic swap)
2. **Inserts** rows into `cast_info`, accumulating maintenance scope from write SQL
3. Confirms **stale reads** stay sub-millisecond and return the pre-update snapshot
4. Runs `AsyncRefresher.flush!` to perform **incremental maintenance** (in-place partition merge — no cache-table rebuild)
5. Validates **updated reads** match the raw query and remain fast

Adjust insert volume with `UPDATE_INSERT_COUNT=8000`.

Compare scripts (`rake benchmark`, `rake benchmark:slow`) measure **bootstrap** cost (one-time) vs raw query time. Use `benchmark:verify_updates` for routine maintenance after writes.

## Original JOB query sources

Benchmark queries are adapted from JOB:

JOB query mappings (see `benchmark/support/source_relations.rb`):

- `1a` → `BenchmarkSources.production_notes_relation`
- `10a` → `BenchmarkSources.russian_voice_actors_relation`
- `19d` → `BenchmarkSources.voicing_actresses_relation`

All 113 JOB queries are available in the [join-order-benchmark repository](https://github.com/gregrahn/join-order-benchmark).
