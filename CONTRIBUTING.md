# Contributing and validation

The [README](README.md) introduces the public DSL. This page separates maintainer workflows from consumer compatibility limits. The test contract map is in [spec/README.md](spec/README.md), benchmark methodology is in [benchmarks/README.md](benchmarks/README.md), and resolved historical matrix results are in [docs/compatibility-results.md](docs/compatibility-results.md).

## Development setup

The default development bundle requires Ruby 3.3 or newer because it uses Rails 8.1. The gem itself supports Ruby 3.1 with ActiveRecord 7.1. Use the compatibility Gemfiles for older supported pairs.

Install dependencies with `bundle install`. Configure a dedicated PostgreSQL test database using `spec/dummy/config/database.yml`, then run `RAILS_ENV=test bundle exec rake db:setup` to create and migrate it.

## Local checks

The default task runs the PostgreSQL RSpec suite and focused correctness/security lint:

```bash
bundle exec rake
```

The broader style audit remains optional:

```bash
bundle exec rake rubocop
```

Package smoke tests build, install, and require the gem from a temporary directory:

```bash
bundle exec rake package:smoke
```

Validate public declarations with:

```bash
bundle exec rbs -I sig validate
```

## Adapter and version matrix

The workflow is in `.github/workflows/compatibility.yml`; see [supported versions](docs/compatibility.md#supported-versions) for the matrix.

The SQLite and MySQL core-contract jobs use the same minimum Ruby/Rails pairings listed above.
`bundle exec rake` runs the PostgreSQL suite and focused correctness/security lint checks. CI uses the same `bundle exec rake lint` gate.
The broader `bundle exec rake rubocop` task remains available for the existing style backlog.

Each PostgreSQL matrix job uses `gemfiles/rails.gemfile`, separate from the development lockfile.
Rails 7.1 uses RSpec Rails 6. Newer lines use RSpec Rails 7.
Adapter jobs use `gemfiles/adapters.gemfile`, which includes the selected database driver.
Matrix lockfiles are local artifacts. Each fresh CI checkout resolves its selected versions independently.

The standalone runner loads this checkout and honors `RAILS_VERSION`, which defaults to `8.1`.
It covers scoped and nested associations, Boolean query composition, aggregates, temporal/Boolean predicates, escaped text, custom serializers, callbacks, diagnostics, and pagination.
It uses temporary fixture tables on PostgreSQL and SQLite. MySQL uses ordinary `compat_*` and `af_boundary_*` fixture tables with cleanup because MySQL cannot reopen temporary tables within a query. Run these scripts against an isolated test database.

```bash
BUNDLE_GEMFILE=gemfiles/adapters.gemfile RAILS_VERSION=8.1 SCRY_ADAPTER=sqlite3 bundle install
BUNDLE_GEMFILE=gemfiles/adapters.gemfile RAILS_VERSION=8.1 SCRY_ADAPTER=sqlite3 bundle exec ruby script/compatibility.rb

# Select mysql2 instead for the MySQL contract run.
BUNDLE_GEMFILE=gemfiles/adapters.gemfile RAILS_VERSION=8.1 SCRY_ADAPTER=mysql2 bundle install
BUNDLE_GEMFILE=gemfiles/adapters.gemfile RAILS_VERSION=8.1 SCRY_ADAPTER=mysql2 bundle exec ruby script/compatibility.rb
```

The MySQL command expects `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, and `MYSQL_DATABASE` when the
defaults do not apply.

The adapter matrix can run both standalone runners on all four supported Rails minor lines with SQLite and MySQL, using the minimum Ruby versions listed above. The commands below show one SQLite cell; run each configured adapter and Rails line to complete the matrix:

```bash
BUNDLE_GEMFILE=gemfiles/adapters.gemfile RAILS_VERSION=8.1 SCRY_ADAPTER=sqlite3 bundle exec ruby script/adapter_regressions.rb
bundle exec rbs -I sig validate
```

The shared regression runner also supports `SCRY_ADAPTER=postgresql`. It covers logical attribute types, enum and custom serialization, candidate pagination, eager loading, derived tables, cache invalidation, and a real Pundit policy scope combined with soft deletion and Boolean filters. Pundit is a test dependency; the gem accepts an already-authorized ActiveRecord relation without depending on a policy library.

## Historical validation evidence

The current compatibility record is a dated local Docker snapshot from 7 September 2026, not a hosted GitHub Actions result. It reports all 12 configured cells passing: four PostgreSQL full suites and eight SQLite/MySQL adapter cells, with RBS validation. See [docs/compatibility-results.md](docs/compatibility-results.md) for resolved versions and exact scope.

The record reports a 935-example development suite with zero failures, focused lint across 147 files with zero offenses, and benchmark cardinality assertions. These outcomes describe that snapshot and should not be presented as a current rerun without repeating the commands.

## Benchmarks

Run the representative PostgreSQL benchmark against an isolated test database:

```bash
OWNERS=1000 CHILDREN=8 TAGS=3 CANDIDATES=500 ITERATIONS=10 EXPLAIN=1 \
  bundle exec ruby benchmarks/query_compilation.rb > /tmp/filter-benchmark.jsonl
```

The runner uses temporary tables inside a transaction, verifies stable SQL and expected result cardinality, and rolls back. Its generated-data timings are not production latency guarantees or a controlled before/after comparison. See [benchmarks/README.md](benchmarks/README.md).

## Changes and review

Keep regression contracts close to the behavior they protect. Preserve caller authorization and tenant scope, Rails lifecycle ordering, adapter boundaries, and source aliases when changing query compilation. Run focused checks first, then the default task and any relevant matrix runner. Do not treat configured CI jobs as evidence until they have actually executed.
