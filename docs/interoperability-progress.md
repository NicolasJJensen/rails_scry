# Interoperability implementation

All 18 review finding groups have regression coverage and fixes. The public filter DSL remains in place.

| Findings | Contract | Implementation |
|---|---|---|
| AF-01 | Rails initializer order; standalone ActiveRecord | Explicit predicate builders; optional Railtie; opt-in Arel extensions |
| AF-02, AF-15, AF-16 | Type policies and cache invalidation | Registry and permission revisions, correct type replacement/removal |
| AF-17 | Temporary configuration isolation | Execution-local overlays with nested restoration |
| AF-18 | Denied model discovery | Empty metadata for denied models; immutable cached enforcement results |
| AF-03, AF-07, AF-08 | Association scopes, aliases, custom keys and through direction | Rails association join construction behind one compatibility boundary |
| AF-04, AF-05, AF-06 | OR, negation, caller scopes and existing joins | Independent membership conditions preserve Boolean composition |
| AF-09 | Nested scoping and zero-inclusive aggregates | One aggregate path preserves complete scoped relations |
| AF-10, AF-11 | PostgreSQL array/JSON discovery and operands | Adapter gating and ActiveRecord type serialization |
| AF-12 | DISTINCT averages and temporal minimums | Registered aggregate builders, result types and empty values |
| AF-13 | Negated empty groups | Boolean identities applied before negation |
| AF-14 | Missing associations and malformed scoping | Consistent FilterError handling for ignore/warn/raise modes |

Additional contracts cover custom aggregate builders, typed custom-property metadata, custom filters returning joined
relations, PostgreSQL JSON/range/network operands, enums, custom ActiveRecord serializers, optional associations, input
limits, cyclic payloads, redacted diagnostics, reload invalidation, and packaging outside the checkout.

## Validation

- Original baseline: **650 examples, 0 failures** on Ruby 3.3.6 / Rails 8.1.2 / PostgreSQL.
- Initial bug regression batch: **43 examples, 43 failures** before implementation.
- Completed full suite: **723 examples, 0 failures**, seed **36690**.
- Package build/install/require tests and standalone/Rails boot tests pass as part of the full suite.
- Adapter contract runner passes on Rails **7.0.8.7**, **7.2.2.2**, and **8.1.3** with SQLite and Ruby 3.3.6,
  including standalone ActiveRecord, scoped associations, aggregate OR/NOT, zero counts, through and self-referential joins.
- An independent compiler review reproduced compatibility checks and found no actionable regression.
- Library lint checks pass across all 27 Ruby files. The repository-wide style backlog has not been reformatted.

The CI matrix also targets Rails 7.1/8.0 and MySQL; those cells have not been executed locally. PostgreSQL-specific
predicates are only advertised on PostgreSQL. Polymorphic belongs_to traversals require a static target allowlist;
composite primary and join keys are supported when the model exposes the complete ordered key. Filter permissions do
not replace application authorization.

The benchmark harness is in `benchmarks/query_compilation.rb`. Equivalent filters produce stable SQL. Its current local
results use a small test dataset and do not establish production-scale performance; see `benchmarks/README.md`.

No commits or staging operations were performed.
