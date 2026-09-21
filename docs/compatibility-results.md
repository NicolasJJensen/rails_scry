# Historical compatibility validation — 7 September 2026

This is a dated validation snapshot. It records the matrix run performed on 7 September and is not evidence that the
full matrix was rerun during the 8 September review.

That historical snapshot exercised the then-current working tree in isolated Linux Docker containers using the repository's
matrix Gemfiles and test commands. These are local execution results, not GitHub Actions results. ActiveRecord and
ActiveSupport versions before 7.1 are unsupported.

## Adapter contracts

Every row passed `script/compatibility.rb`, all 119 examples in `script/adapter_regressions.rb`, and `rbs -I sig validate` on both SQLite and MySQL 8.4.

| Rails line | Ruby tested | ActiveRecord resolved | SQLite | MySQL |
|---|---|---|---|---|
| 7.1 | 3.1.7 | 7.1.6 | Pass | Pass |
| 7.2 | 3.2.11 | 7.2.3.2 | Pass | Pass |
| 8.0 | 3.3.12 | 8.0.5.1 | Pass | Pass |
| 8.1 | 3.3.12 | 8.1.3 | Pass | Pass |

## Full PostgreSQL regression suite

Every row passed `bundle exec rake db:setup` followed by all 935 RSpec examples against PostgreSQL 16, including package build/install/require tests.

| Rails line | Ruby tested | ActiveRecord resolved | Result |
|---|---|---|---|
| 7.1 | 3.1.7 | 7.1.6 | Pass |
| 7.2 | 3.2.11 | 7.2.3 | Pass |
| 8.0 | 3.3.12 | 8.0.2 | Pass |
| 8.1 | 3.3.12 | 8.1.3.1 | Pass |

All 12 configured version/adapter cells passed in that 7 September snapshot. The Rails bundle and standalone adapter
bundle resolve independently, so their ActiveRecord patch versions differ. Each matrix cell used an isolated database;
fixture changes could not leak between cells.

## Test dependency repairs

The PostgreSQL matrix Gemfile now includes RuboCop because loading the Rakefile requires `rubocop/rake_task`, including for `db:setup`. It also constrains JSON to version 2 because the resolved Rails JSON encoders pass `quirks_mode`, which JSON 3 rejects during migration setup. These are test-bundle constraints, not additional gem runtime dependencies. Dependency-contract tests cover both repairs.

Package smoke tests also clear `BUNDLER_SETUP` in child processes. Newer Ruby images use this variable to activate Bundler automatically; retaining it caused package checks to load the development lockfile instead of testing the installed gem independently. The existing package build/install/require regressions cover this isolation boundary.

The first local MySQL startup check returned before authenticated connections were ready. The isolated runner was corrected to wait for an authenticated TCP query; the affected cell then passed. This startup failure was separate from the filtering contracts.

## Other evidence

- Development suite: 935 examples, zero failures, on Ruby 3.3.6 / ActiveRecord 8.1.2.
- Focused lint: 147 files, zero offenses.
- Representative PostgreSQL benchmark: all nine cardinality assertions passed; see [measurements](../benchmarks/README.md).
- Shared contracts exercise all four review regressions plus composition, discovery invalidation, custom operands, and caller-scope containment.

This evidence covers the documented contracts. It does not imply support for every SQL relation shape or every third-party integration.
