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

On the `xlarge` synthetic dataset (2M `cast_info` rows), these views run for seconds on SQLite while the materialized read stays sub-millisecond:

| View | Raw query | MV read | Speedup |
|------|-----------|---------|---------|
| `GenderPairingStatsView` | ~7.4s | ~1.1ms | ~6,700× |
| `CompanyMovieCrossView` | ~7.2s | ~1.7ms | ~4,100× |
| `PersonMovieNetworkView` | ~13.2s | ~1.6ms | ~8,200× |
| `CastCoappearanceView` | ~19.5s | ~1.1ms | ~18,000× |

```bash
JOB_SCALE=xlarge bundle exec rake benchmark:setup   # required for benchmark:slow
bundle exec rake benchmark:slow
```

`benchmark:slow` refuses to run on databases smaller than xlarge (checks `cast_info` row count).
If xlarge is still fast on your machine, use `JOB_SCALE=stress`. (Timings are from one
reference machine; absolute numbers vary by hardware, but the order of magnitude holds.)

## Lifecycle simulation (the full flow)

Walk a materialized view through its entire lifecycle as an application would use it, on whatever scale is present (xlarge recommended for the real effect):

```bash
JOB_SCALE=xlarge bundle exec rake benchmark:setup
JOB_DB=benchmark/fixtures/job.sqlite bundle exec rake benchmark:lifecycle
```

The script prints the real result values (not just timings) and asserts each phase, so a clean run proves the whole flow works:

1. **Cold read** — the view has never been built; the read falls through to the source query and returns correct results without materializing anything.
2. **Build** — an explicit `rebuild!(confirm: true)`, the only full-scan path.
3. **Fast reads** — the cache hit vs the raw source query (the speedup).
4. **Write → maintenance → updated read** — dependency writes mark the view dirty, a stale read still returns the previous snapshot fast, then in-place maintenance updates the affected rows.

Adjust the write volume with `UPDATE_INSERT_COUNT=8000`.

## Update verification (incremental maintenance)

A focused proof that routine maintenance never rebuilds or swaps the cache table:

```bash
bundle exec rake benchmark:verify_updates
```

The script:

1. **Bootstraps** the cache table once if missing (`INSERT … SELECT` + atomic swap)
2. **Inserts** rows into `cast_info`, accumulating maintenance scope on commit
3. Confirms **stale reads** stay sub-millisecond and return the pre-update snapshot
4. Runs `refresh!` for **incremental maintenance** (in-place partition merge — asserts no cache-table rebuild/swap via SQL recorders)
5. Validates **updated reads** match the raw query and remain fast

Adjust insert volume with `UPDATE_INSERT_COUNT=8000`.

Compare scripts (`rake benchmark`, `rake benchmark:slow`) measure **bootstrap** cost (one-time) vs raw query time. Use `benchmark:lifecycle` for the end-to-end story and `benchmark:verify_updates` to assert the maintenance internals.

## Original JOB query sources

Benchmark queries are adapted from JOB:

JOB query mappings (see `benchmark/support/source_relations.rb`):

- `1a` → `BenchmarkSources.production_notes_relation`
- `10a` → `BenchmarkSources.russian_voice_actors_relation`
- `19d` → `BenchmarkSources.voicing_actresses_relation`

All 113 JOB queries are available in the [join-order-benchmark repository](https://github.com/gregrahn/join-order-benchmark).
