# Compatibility and limits

See the [README](../README.md) for an introduction. This page records consumer-facing support boundaries. For test commands and dated validation evidence, see [CONTRIBUTING.md](../CONTRIBUTING.md). For benchmark methodology, see [benchmarks/README.md](../benchmarks/README.md).

## Contents

- [Supported versions](#supported-versions)
- [Query and extension contracts](#query-and-extension-contracts)
- [Relation composition](#relation-composition)

## Supported versions

The supported matrix is:

| Rails line | Minimum Ruby |
|---|---|
| 7.1 | 3.1 |
| 7.2 | 3.2 |
| 8.0 | 3.3 |
| 8.1 | 3.3 |

The gem requires Ruby >= 3.1, ActiveRecord and ActiveSupport >= 7.1 and < 9. Rails and Railties remain optional integration dependencies. Native ActiveRecord CTE support is required; Rails 7.0 and earlier are unsupported.

PostgreSQL runs the full regression suite. SQLite and MySQL run adapter-neutral core and shared boundary contracts. PostgreSQL-only predicates are gated by adapter. The gem accepts an already-authorized relation and does not depend on a policy library.

## Query and extension contracts

Discovery uses the model's logical attribute type, with physical array metadata retained for adapter-native predicates. Property-result aggregates serialize operands with the associated model's attribute type. Changing a filterable model's attributes, table name, or schema information invalidates dependent discovery caches. Call `reset_column_information` after changing schema, as required by ActiveRecord.

Extension registration rejects abstract filter classes, incompatible constructors, malformed metadata, and callbacks that cannot accept the documented positional arguments. Zero-operand predicate lambdas can accept just the attribute. An `arel_predicate` method must already be installed when the predicate is registered; install Arel extensions before calling `register_predicate`. Callback errors during discovery follow `callback_error_policy`. Registry entries, including temporary configuration snapshots, are immutable; change definitions through registration APIs.

Public RBS declarations cover configuration, registries, discovery, diagnostics, permissions, and filter extensions. ActiveRecord and Arel objects remain `untyped` so consumers do not need an additional Rails signature package. Signature validation checks declaration consistency; runtime behavior is covered by the regression suite.

Polymorphic `belongs_to` traversals require a static target allowlist, and composite primary and join keys are
supported when the model exposes the complete ordered key. Association scopes with `limit` or `offset` are evaluated
per owner using a windowed candidate relation. Owner-dependent Ruby scopes cannot be joined and are rejected.

A custom `FROM` must use an Arel table alias, and the incoming relation must already reference that alias correctly. Custom filters return `Scry::Result`, not a bare relation. Use `source_relation` and `source_attribute(:name)` when a filter must read the caller's derived source. Successful custom relations must retain a selectable model primary key. Grouped membership projections must group by the current source's primary key. A different table's identically named key does not qualify. Use an Arel attribute or a simple qualified identifier; opaque SQL grouping expressions are rejected.

When a custom relation uses `LIMIT` or `OFFSET`, ordering by a selected alias that would be removed by primary-key projection is rejected during compilation. The diagnostic names the alias and recommends ordering by the aggregate expression directly (for example, `order(table[:name].maximum.desc)`) or exposing the ordering field through an Arel derived source. Without pagination, ordering is discarded safely. This error follows the configured error-handling and invalid-filter policies.
Filter permissions control filtering capabilities. Mandatory model scopes define the rows the engine can examine. Hosts still choose and register their authorization policy.

## Relation composition

Native ActiveRecord CTE support is required. ActiveRecord 7.0 and earlier are no longer supported.
Custom filter relations can use `with(...)`; Boolean composition preserves their CTE definitions through a primary-key subquery.
Ordering and pagination remain on the caller relation unless requested by the filter's group selection modifiers. The compiler preserves the caller's authorization and tenant scope.
