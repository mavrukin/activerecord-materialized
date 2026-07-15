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
