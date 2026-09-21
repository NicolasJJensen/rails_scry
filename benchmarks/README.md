# Representative query benchmarks

Run `bundle exec ruby benchmarks/query_compilation.rb` against a local PostgreSQL test database. `PGDATABASE` defaults to `scry_test`. Standard PostgreSQL environment variables select the host and user.

The script creates temporary tables inside a transaction. It rolls back the transaction after all measurements. It does not change application records or persistent schema. The connection closes and removes temporary tables if the process stops.

The default dataset contains 1,000 owners, 7,200 children, and 21,600 tags. Every tenth owner has no children. Each remaining owner has eight children. Each child has three tags, including one marker tag. Foreign-key indexes support association joins.

Use environment variables to control the dataset:

| Variable | Default | Allowed range |
|----------|---------|---------------|
| `OWNERS` | 1,000 | 1–10,000 |
| `CHILDREN` | 8 | 1–30 |
| `TAGS` | 3 | 1–10 |
| `CANDIDATES` | 500 | 1–10,000 |
| `ITERATIONS` | 50 | 1–10,000 |
| `EXPLAIN` | unset | `1` adds PostgreSQL execution plans |

The script rejects datasets above 1,000,000 rows. Candidate counts cannot exceed the generated child count. Compilation measurements repeat the same filter and verify stable SQL. Each query also reports its matching owner count and asserts that count against the expected cardinality derived from the generated dataset. A mismatch aborts the run, so a benchmark cannot silently report timing for a query that returns the wrong set.

```bash
OWNERS=1000 CHILDREN=8 TAGS=3 CANDIDATES=500 ITERATIONS=10 EXPLAIN=1 \
  bundle exec ruby benchmarks/query_compilation.rb > /tmp/filter-benchmark.jsonl
```

A local run on Ruby 3.3.6 and ActiveRecord 8.1.2 produced these measurements with the default dataset and ten compilation iterations:

| Query | Average compilation, ms | PostgreSQL execution, ms |
|-------|-------------------------|--------------------------|
| Property | 0.129 | 0.052 |
| Aggregate OR property | 0.276 | 2.729 |
| Zero count | 0.264 | 3.253 |
| Fifty properties | 2.896 | 4.207 |
| Nested scoped `has_all` | 0.640 | 35.885 |
| Nested scoped `only_has_all` | 0.813 | 45.468 |
| 500 candidate IDs | 1.549 | 1.595 |

The nested set filters return no owners because their global candidate set exceeds each owner's child set. They still measure nested association and set-count work. Execution values come from one `EXPLAIN ANALYZE` per query, after a count query warms the data. These values describe this generated dataset, not production latency guarantees. Compare plans and data distributions before changing query strategy or indexes.

## Interoperability follow-up measurements

The runner now accepts `TENANTS` (default 10, range 1–100) and reports `candidate_subqueries`. On Ruby 3.3.6 / ActiveRecord 8.1.2 / PostgreSQL with 1,000 owners, 7,200 children, 21,600 tags, ten tenants, and ten compilation iterations:

| Query | Compilation ms | Execution ms | SQL bytes | Candidate subqueries | Matches |
|---|---:|---:|---:|---:|---:|
| Tenant + paginated `has_all` | 0.396 | 0.105 | 1,244 | 3 | 1 |
| Tenant + paginated `only_has_all` | 0.465 | 2.336 | 2,015 | 5 | 1 |
| Nested scoped `has_all` | 0.655 | 41.587 | 1,659 | 0 | 0 |
| Nested scoped `only_has_all` | 1.014 | 52.788 | 2,732 | 0 | 0 |

The two tenant cases select an ordered page of one owner's children and match that owner within its tenant. This exercises successful exclusive membership at realistic fanout. The counter measures appearances of the paginated derived candidate query, not all nested membership queries. These queries repeat the candidate page three and five times respectively. Keep this measurable before introducing adapter-specific CTE materialization: this warm local dataset does not establish a general performance benefit. The nested cases remain substantially slower and need workload-specific plans before optimization. Execution times are single warm `EXPLAIN ANALYZE` samples, not percentiles.

## Council follow-up measurements

A new bounded run used 1,000 owners, 7,200 children, 21,600 tags, 500 candidate IDs, ten tenants, and ten compilation iterations. Every query's result cardinality matched its expected value. Ruby was 3.3.6 and ActiveRecord was 8.1.2.

| Query | Compilation ms | Execution ms | Matches |
|---|---:|---:|---:|
| Zero-inclusive count | 0.313 | 7.098 | 100 |
| Nested scoped `has_all` | 0.693 | 40.666 | 0 |
| Nested scoped `only_has_all` | 1.074 | 54.647 | 0 |
| 500 candidate IDs | 1.404 | 1.766 | 63 |
| Tenant + paginated `has_all` | 0.410 | 0.083 | 1 |
| Tenant + paginated `only_has_all` | 0.506 | 2.272 | 1 |

Execution values are single warm `EXPLAIN ANALYZE` samples. Docker compatibility preparation ran on the same machine, so these timings are not a controlled before/after comparison. The run verifies query results and preserves measurable cases for future optimization. It does not justify a query-strategy change.
