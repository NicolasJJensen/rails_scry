# Council follow-up

Implementation followed the requested order: regression contracts first, interoperability improvements second, and remaining operand failures last. ActiveRecord and ActiveSupport now require 7.1 or newer. Native CTE support has no legacy version fallback.

| Work | Status |
|---|---|
| AF-C1 CTE relation composition | Fixed; AND, OR, and negation regression contracts pass |
| AF-C2 qualified grouped keys | Fixed; canonical source and alias controls pass; wrong-source keys follow diagnostic, reject, and match-none policies |
| AF-C3 complete discovery | Fixed; aggregate metadata, result types, comparisons, labels, and arities share one discovery schema |
| AF-C4 custom association operands | Fixed; scalar and zero-operand callbacks preserve inputs, while set predicates retain ID normalization |
| Composition coverage | Expanded across CTEs, grouped aliases, candidate pagination, Boolean operators, and caller-scope containment |
| SQL-shape handling | Qualified Arel/source identity checks and a narrow identifier grammar; unsupported grouping is rejected |
| Compatibility minimum | Raised to ActiveRecord 7.1; Rails 7.0 removed from all CI cells |
| Performance evidence | Benchmark now checks every result cardinality; representative measurements completed with all nine cardinality assertions passing |
| Maintenance | ScopeEvaluator removed; related historical tests renamed by behavior; development Ruby requirement documented |
| Full compatibility matrix | All 12 version/adapter cells passed in isolated Docker runs; see compatibility-results.md |

## Test-first evidence

New tests exposed CTE loss, wrong-source grouping acceptance, scalar/zero-operand normalization, and missing aggregate discovery. A canonical raw-Arel grouping control also exposed incorrect Group-node unwrapping. The fixes retain valid Arel grouping and reject unsupported source identities.

The initial combined test batch had 113 examples and 14 failures, including a locale fixture setup error that was corrected separately. After the query/discovery improvements, only the two operand tests failed. The operand fix made that focused batch pass. Additional context, diagnostic-policy, and composition controls brought the shared suite to 119 passing examples.

## Completed local validation

- `bundle exec rake`: 935 examples, 0 failures; 147 files linted, no offenses.
- Standalone SQLite shared contracts: 119 examples, 0 failures.
- Standalone PostgreSQL shared contracts: 119 examples, 0 failures.
- RBS validation: passed.
- Docker PostgreSQL matrix: 935 examples, zero failures on each of Rails 7.1, 7.2, 8.0, and 8.1 with the configured minimum Ruby lines.
- Docker SQLite/MySQL matrix: both standalone runners and RBS validation passed in all eight cells, including 119 shared examples per cell.

Matrix execution also exposed and resolved test infrastructure issues: a missing RuboCop dependency when loading Rake, Rails JSON encoding incompatibility with JSON 3, and inherited `BUNDLER_SETUP` activation in package subprocesses. See [exact resolved versions and results](compatibility-results.md). Hosted GitHub Actions was not run.

The full local suite uses Ruby 3.3.6 and locked ActiveRecord 8.1.2. Standalone shared checks use installed ActiveRecord 8.1.3. No commits or staging operations were performed.

Representative PostgreSQL benchmark: 1,000 owners, 7,200 children, 21,600 tags, 500 candidates, ten compilation iterations per query. All nine result-count assertions passed. See `benchmarks/README.md` for timings and measurement limits.
