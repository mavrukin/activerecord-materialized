# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`activerecord-materialized` is a Ruby gem providing **application-level materialized views** for Rails/ActiveRecord on databases without native MV support (MySQL, MariaDB, SQLite). It precomputes expensive analytical queries into cache tables, refreshes them in the background when dependency data changes (refresh-on-write, not refresh-on-read), and serves reads through a transparent ActiveRecord API. It is a standalone gem — there is no host Rails app in this repo. Ruby >= 3.4, Rails/ActiveRecord >= 8.0.

## Workflow

Follow this end-to-end flow for any non-trivial unit of work:

1. **Open a GitHub issue** describing the work. Populate it well — context/motivation, scope, and acceptance criteria — not a one-liner.
2. **Branch** off `main` with a name that includes the issue number plus a short description (e.g. `17-speed-up-lefthook-scoped-checks`).
3. **Implement.** Always add good tests. Reduce duplication, and clean things up opportunistically as you touch surrounding code.
4. **Commit and push**, then **verify CI passes** (`.github/workflows/ci.yml`). Improve the CI itself when it's warranted.
5. **Open a descriptive, high-standard PR** and **stop for the user to review** — do not merge.

## Quality bar

Aim for code that reads as an **exemplar of idiomatic Ruby/Rails**:

- Relentlessly reduce duplication; factor shared logic rather than copy-paste.
- Lean on existing libraries, gem dependencies, and **built-in Ruby/Rails/ActiveRecord patterns** before writing bespoke code. Reuse what's already in the codebase.
- Prefer expressive, idiomatic constructs (Enumerable methods, ActiveSupport helpers, Arel) over hand-rolled equivalents.
- The standard is exceptional: a reader should consider the result a model of what high-quality Ruby/Rails code looks like.

## Commands

```bash
bin/setup                       # bundle install + lefthook install + tapioca gems
bin/ci                          # run the full local gate: RuboCop, Sorbet, RSpec

bundle exec rspec               # full test suite
bundle exec rspec path/to/foo_spec.rb            # single file
bundle exec rspec path/to/foo_spec.rb:42         # single example by line
bin/affected-specs <files...>   # print specs affected by changed files (mapping logic, see below)

bundle exec rubocop lib/ bin/ --parallel         # lint (CI scope)
bundle exec srb tc              # Sorbet typecheck
bundle exec tapioca gems        # regenerate gem RBIs after dependency changes
```

Benchmarks (JOB-schema SQLite, see `benchmark/DATA.md`):

```bash
JOB_SCALE=medium bundle exec rake benchmark:setup   # generate DB (medium/large/xlarge)
bundle exec rake benchmark                           # raw vs MV comparison
bundle exec rake benchmark:slow                      # targets multi-second raw queries
bundle exec rake benchmark:verify_updates            # proves refresh-on-write
```

## CI vs local hooks

Local `lefthook` hooks are **scoped to changed files** for speed; CI (`.github/workflows/ci.yml`) runs everything. Key consequences:

- `async_refresher_flush_spec.rb` is the **heavy benchmark integration spec**. It is *excluded* from the main RSpec CI job and from `bin/affected-specs`; CI runs it separately after generating a `medium` benchmark DB. `bin/hook-rspec` and the affected-specs mapping deliberately skip it.
- If you change a `lib/` file, `bin/affected-specs` maps it to the relevant spec(s) via `SPEC_OVERRIDES` (not always a 1:1 name match). Changes to `spec_helper.rb`, `spec/support/`, the gemspec, RuboCop/lefthook/sorbet config, or CI workflows trigger the **full** fast suite. When in doubt, run `bundle exec rspec` (or `bin/ci`) before pushing.

## Hard conventions (enforced by hooks/CI)

- **Every `lib/**/*.rb` file must start with `# typed: strict`** (line 1, before `# frozen_string_literal: true`). Enforced by `bin/check-strict-sigils` — no `typed: true`/`typed: false` allowed in `lib/`. This means new methods need full Sorbet `sig`s.
- Double-quoted strings, `Layout/LineLength` max 120, `Metrics/MethodLength` max 20 (RuboCop config in `.rubocop.yml`). `benchmark/**/*.rb` and `sorbet/**` are excluded from RuboCop.
- View `materialized_from` sources must be `ActiveRecord::Relation` objects (standard query API + Arel), **never raw SQL strings**.

## Architecture

The library splits the **write path** (maintenance) from the **read path** (always fast). Entry point `lib/activerecord/materialized.rb` requires everything and installs hooks via `ActiveSupport.on_load(:active_record)`.

A view is a subclass of `ActiveRecord::Materialized::View` backed by a physical cache table (e.g. `mv_sales_summary`). The DSL is split across `view_*_class_methods.rb` modules (configuration, refresh policy, incremental, query access) mixed into the base `View`.

**Write/refresh lifecycle:**
1. `DependencyTrackable` installs `after_*_commit` callbacks on every `depends_on` model; `DependencyRegistry` maps tables → view classes, `TableModelRegistry` maps tables → models.
2. On a dependency write, `MaintenanceDeltaBuilder` derives affected `GROUP BY` partition keys from the ActiveRecord change payload and records them in `MaintenanceStore` (widening to all partitions when scope is unknown).
3. `RefreshScheduler` dispatches the strategy: `:async` (debounced, via `AsyncRefresher` in-process thread or `RefreshJob`/ActiveJob), `:immediate`, or `:manual`.
4. `IncrementalMaintainer` (the default, hot path) deletes + re-aggregates only affected partitions in place — no DDL, no atomic swap. `Refresher` orchestrates bootstrap and full refresh; `RelationCacheWriter` materializes rows and does the atomic table swap used on first build / `refresh_mode :full`.
5. `Metadata`/`MetadataRecord` track `dirty`, `maintenance_payload`, `last_refreshed_at`, `row_count`, errors in the `ar_materialized_view_metadata` table.

**Read path:** queries (`where`, `find`, `count`, scopes) hit the cache table directly and never trigger refresh.

`ViewDefinition` inspects the source relation for `GROUP BY` maintenance keys. `QueryExpressions` provides portable Arel aggregation helpers (`sum_as`, `count_distinct_as`, etc.) for use in view definitions. Generators live in `lib/generators/activerecord_materialized/` (`install`, `view`).

When a view definition grows large, extract its relation to a module/class method — see `spec/support/view_sources.rb` and `benchmark/support/source_relations.rb` for the established pattern.
