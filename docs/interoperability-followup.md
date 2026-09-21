# Interoperability follow-up

The accepted scope includes all ten review findings and all eight improvement areas from the 7 September review.

| Work | Regression tests | Implementation | Verification |
|---|---|---|---|
| Invalid association IDs | Added | Complete | Passed |
| Numeric range normalization | Added | Complete | Passed |
| Candidate pagination and cardinality | Added | Complete | Passed |
| Logical attribute types | Added | Complete | Passed |
| Aggregate serialization | Added | Complete | Passed |
| Derived FROM values | Added | Complete | Passed |
| Operand shapes and early diagnostics | Added | Complete | Passed |
| Discovery programming errors | Added | Complete | Passed |
| Immutable snapshot restoration | Added | Complete | Passed |
| Schema and table invalidation | Added | Complete | Passed |
| Extension registration and callback contracts | Added | Complete | Passed |
| Shared adapter/version regressions | 39 shared examples | Complete | PostgreSQL + SQLite: all five Rails minors passed; MySQL CI configured |
| Representative integration contracts | Pundit, soft deletion, tenant scopes, OR/NOT, pagination, serialized JSON | Complete | Passed |
| Private Rails compatibility boundary | Shared eager-loading, projection, association tests | Complete | All five Rails minors passed |
| Candidate query measurements | Tenant/fanout benchmark | Complete | Measurements recorded in benchmarks/README.md |
| Public RBS declarations | RBS validation | Complete | Passed |
| Bounded diagnostic identifiers | Added | Complete | Passed |

Existing baseline: 780 examples passed with seed 47732 before this work. No commits or staging operations are included.

## Additional review regressions

Final review also added coverage and fixes for dependent parent discovery after child type changes, required keyword arguments on ordinary callbacks, abstract filter extensions, custom-serialized ranges on derived sources, and distinct eager-loaded candidate relations. MySQL fixtures use ordinary test tables with cleanup; derived-value assertions do not depend on case-sensitive collation.

## Validation

- Baseline: 780 examples passed before this work.
- Initial original-review regressions: 21 examples, 20 failures before fixes; one pre-existing valid-ID control passed.
- Final PostgreSQL suite: 819 examples, zero failures.
- Shared suite: 39 examples, zero failures in each of ten local cells: PostgreSQL and SQLite on ActiveRecord 7.0.10, 7.1.4.2, 7.2.3.2, 8.0.2, and 8.1.3, with Ruby 3.3.6.
- Public declarations: `bundle exec rbs -I sig validate` passed.
- Runtime lint: 27 files inspected, zero Lint offenses. `git diff --check` passed.
- MySQL CI is configured for all five Rails minor lines. No local MySQL server is available, so those jobs have not been executed here. The complete PostgreSQL suite was run locally on ActiveRecord 8.1.2; the other local minor runs cover the shared contracts.

The benchmark confirms repeated candidate subqueries and records tenant-scoped execution plans/times. It retains portable SQL rather than introducing an unmeasured adapter-specific optimization. Public signatures intentionally leave external ActiveRecord/Arel values untyped. No commits or staging operations were performed.
