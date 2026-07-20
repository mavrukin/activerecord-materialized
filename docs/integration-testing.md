# Integration testing against real databases

The fast test suite runs against in-process SQLite. The **integration matrix**
(`spec/integration/`, issue #70) additionally exercises the gem against **real
MySQL and PostgreSQL** — proving the write → `ingest_change` → maintain → read
path, DDL, the atomic table swap, cache-column type inference, and
partition-scoped maintenance are portable across engines.

CI runs one workflow per adapter, each with its own status badge (see the
[Database compatibility](../README.md#database-compatibility) matrix).

## What it does

For each configured adapter, [`spec/integration/cdc_matrix_spec.rb`](../spec/integration/cdc_matrix_spec.rb)
drives the reusable [`CdcScenario`](../benchmark/support/cdc_scenario.rb) harness: it
performs a **raw `INSERT` that bypasses ActiveRecord callbacks**, relays the change
through `ActiveRecord::Materialized.ingest_change`, and asserts the view converges
via *scoped* maintenance — all observed through the gem's real instrumentation events.

> **Capture-shaped, by design.** The change descriptor is synthesized at the write
> site (as a change-stream consumer would relay it), not decoded from the MySQL
> binlog / Postgres WAL. Decoding the real logs end-to-end is tracked as a
> follow-up. The servers are still started **configured for CDC** (ROW binlog,
> `wal_level=logical`) to match production and ready that work.

## What the suite covers

- **`integration_adapters_spec`** — pure-Ruby registry unit checks (env parsing, `ARM_ONLY`, availability). Runs in the fast gate; no database.
- **`cdc_matrix_spec`** (#70) — per engine: a raw write bypasses callbacks, is relayed via `ingest_change`, and the view converges via scoped maintenance. The descriptor is synthesized at the write site (the fast, capture-shaped default).
- **`cdc_real_capture_spec`** (#80) — the literal CDC path: a raw write is **decoded from the database's own change log** (a `test_decoding` logical slot on Postgres; the ROW binlog via `mysqlbinlog` on MySQL) into a normalized descriptor, relayed via `ingest_change`, and the view converges — no write-site synthesis. Capture strategies live in [`support/cdc_capture.rb`](../spec/integration/support/cdc_capture.rb), selected per adapter by `IntegrationAdapters::CAPTURE`. SQLite has no server change log and is skipped.
- **`load_bearing_spec`** (#84) — per engine: a wide multi-aggregate view (`COUNT`/`SUM`/`AVG`/`MIN`/`MAX`/`COUNT DISTINCT`) and a join-keyed view, driven with varied mutations (create, partition-moving update, delete, bulk write) at volume, asserting convergence and engine-consistent inferred column types.
- **`concurrency_spec`** (#84) — spawns concurrent writer and reader processes while the parent rebuilds the view mid-flight, asserting no process crashes, no torn/empty reads, and re-convergence. Runs on **MySQL and PostgreSQL**: workers are *spawned* as fresh processes (not forked), so each opens its own clean connection and libpq's fork-unsafety is avoided. SQLite is skipped — its in-process `:memory:` database isn't shared across separate processes.

## Running the matrix locally

Requires Docker. The `pg` and `trilogy` adapters are **not** installed or loaded by
default (the Gemfile gates them behind `install_if`), so the fast suite and
contributors without client libraries never compile native extensions. Set
`ARM_INTEGRATION=1` for the session — it enables them at both install and run time:

```bash
export ARM_INTEGRATION=1
bundle install

bundle exec rake integration:up        # MySQL on host :3307, Postgres on host :5433

ARM_MYSQL_HOST=127.0.0.1 ARM_MYSQL_PORT=3307 \
ARM_MYSQL_USER=root ARM_MYSQL_PASSWORD=root ARM_MYSQL_DATABASE=arm_test \
ARM_PG_URL=postgres://postgres:postgres@127.0.0.1:5433/arm_test \
  bundle exec rake integration

bundle exec rake integration:down      # stop and remove the containers
```

Host ports **3307/5433** (not the defaults 3306/5432) are used so a MySQL or
Postgres already running on your machine does not shadow the containers.

The MySQL real-binlog capture (`cdc_real_capture_spec`) shells out to **`mysqlbinlog`**
(`--read-from-remote-server`), which is **not** in the container — install the MySQL
client on your host (e.g. `brew install mysql-client`, or a `mysql-client` package). It
is gated on availability: absent, that example is skipped with a logged reason (CI
installs it so the path is always exercised). Postgres needs no extra tooling —
`test_decoding` is built in and `wal_level=logical` is set by `docker-compose.yml`.

### Connection environment

Each adapter reads its connection from the environment (a URL wins over discrete parts):

| Variable | Purpose |
|----------|---------|
| `ARM_ONLY` | Comma-separated adapters to run (e.g. `sqlite,mysql`); unset runs all |
| `ARM_MYSQL_URL` *or* `ARM_MYSQL_HOST`/`PORT`/`USER`/`PASSWORD`/`DATABASE` | MySQL connection |
| `ARM_PG_URL` *or* `ARM_PG_HOST`/`PORT`/`USER`/`PASSWORD`/`DATABASE` | PostgreSQL connection |

An adapter with no configuration (or an unreachable server) is **skipped with a
logged reason**, never silently — SQLite always runs in-process.

## Adding a new database type

Adding an engine (e.g. MariaDB, SQL Server) is a configuration change — the specs
never change:

1. Add the key to `IntegrationAdapters::KEYS` and a `SETTINGS` entry (adapter name,
   `ARM_*` env prefix, default port) plus a `LABELS` entry in
   [`spec/integration/adapters.rb`](../spec/integration/adapters.rb).
2. Add its client gem to the `install_if` block in the [`Gemfile`](../Gemfile).
3. Add a caller workflow `.github/workflows/db-<name>.yml` (copy an existing one,
   change `name:` and `adapter:`) and a badge row to the README matrix. Provision
   the server in [`.github/workflows/integration.yml`](../.github/workflows/integration.yml)
   and [`docker-compose.yml`](../docker-compose.yml).
