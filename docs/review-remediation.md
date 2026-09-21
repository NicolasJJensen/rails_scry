# Review remediation

Adapter support is a hard constraint applied after permission specificity, with a second guard at execution. More specific permissions can restore predicates excluded by broader permissions, within the supported type and adapter universe.

| Contract | Regression coverage | Result |
|---|---|---|
| Named permissions respect subclass overrides | `policy_inheritance_spec` | Fixed |
| JSON arrays and serialized operands preserve complete values | `operand_shapes_spec` | Fixed |
| Association sets retain missing requested IDs and handle empty scopes | `association_sets_spec` | Fixed |
| Adapter constraints survive permission overrides and custom filter bypasses | `policy_specificity_spec`, `adapter_enforcement_spec` | Fixed |
| Temporal filters work without Rails time zones | `temporal_runtime_spec` | Fixed |
| Aggregate operands use declared result types | `aggregate_operands_spec` | Fixed |
| Custom property metadata and JSON definitions work consistently | `discovery_consistency_spec`, `custom_expansion_spec` | Fixed |
| Root permission failures deny access and produce diagnostics | `permission_diagnostics_spec` | Fixed |
| Discovery invalidates when associated model permissions change | `discovery_consistency_spec` | Fixed |
| Version and adapter commands load the intended checkout | `compatibility_workflow_spec`, `adapter_runtime_spec` | Fixed; remote matrix pending |
| Discovery exposes executable aggregates and properties | `discovery_consistency_spec` | Implemented |
| Default scopes, tenant boundaries, and pagination compose correctly | `application_scopes_spec` | Verified |
| Literal wildcard matching works across adapters | `operand_shapes_spec`, standalone adapter runner | Fixed |

The spec names above are under `spec/scry/interoperability/`.

## Improvements

- Normalize permission keys and custom filter input consistently.
- Keep adapter-specific casting in the compatibility boundary.
- Remove obsolete cache bookkeeping and thread cleanup state.
- Separate dependency matrix bundles from the development lockfile.
- Expand the standalone adapter runner to 19 contracts.
- Document callback resolution, specificity, strict permissions, and association scope semantics in README.
- Move 30 legacy contexts into named regression files, preserving their assertions. See `spec/README.md`.
- Add configurable benchmarks using temporary data. Measurements and limitations are in `benchmarks/README.md`.

## Verification

The previous complete suite passed 723 examples. Regression-first runs reproduced defects in operands, temporal behavior, policy resolution, association sets, aggregate casting, and compatibility setup before their fixes. Follow-up tests cover additional execution guards and integration boundaries.

- Main PostgreSQL suite, Rails/ActiveRecord 8.1.2: **780 examples, 0 failures**, seed 54551.
- Isolated Rails 8.0 PostgreSQL suite: **780 examples, 0 failures**, seed 9320.
- Library lint: **27 files, no offenses** (`Lint` cops).
- Isolated Rails 8.0 and 8.1 infrastructure tests: **5 examples each, 0 failures**.
- Standalone SQLite adapter contracts: passed with ActiveRecord 8.1.3.
- Rails 7.0–7.2 and MySQL remain unverified locally because the required complete dependency bundles are unavailable. The updated CI matrix covers them; no remote CI result is claimed.

Two aggregate permission fixtures now use an allowed timestamp/minimum instead of a forbidden foreign key/sum, so they continue to test set operations against executable aggregate metadata. Canonical predicate ordering remains covered by unchanged legacy assertions.
