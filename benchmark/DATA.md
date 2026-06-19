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

On the `xlarge` synthetic dataset, these queries consistently run in the **1–5 second** range on SQLite:

| File | Typical raw time |
|------|------------------|
| `benchmark/queries/gender_pairing_stats.sql` | ~2.7s |
| `benchmark/queries/company_movie_cross.sql` | ~2.2s |
| `benchmark/queries/person_movie_network.sql` | ~4.5s |

```bash
JOB_SCALE=xlarge bundle exec rake benchmark:setup   # required for benchmark:slow
bundle exec rake benchmark:slow
```

`benchmark:slow` refuses to run on databases smaller than xlarge (checks `cast_info` row count).
If xlarge is still fast on your machine, use `JOB_SCALE=stress`.

## Update simulation

Verify refresh-on-write: dependency writes schedule a background refresh while reads stay fast:

```bash
bundle exec rake benchmark:verify_updates
```

The script inserts rows into `cast_info`, confirms the view is marked dirty, reads still return the cached snapshot in sub-millisecond time, then runs `AsyncRefresher.flush!` to complete the scheduled refresh and validates results match the raw query.

Adjust insert volume with `UPDATE_INSERT_COUNT=8000`.

## Original JOB query sources

Benchmark queries are adapted from JOB:

- `1a` → `benchmark/queries/production_notes.sql`
- `10a` → `benchmark/queries/russian_voice_actors.sql`
- `19d` → `benchmark/queries/voicing_actresses.sql`

All 113 JOB queries are available in the [join-order-benchmark repository](https://github.com/gregrahn/join-order-benchmark).
