# Capability discovery

Use `Scry.filter_capabilities` to build a dynamic filter UI from the exact
properties, associations, predicates, ordering, and aggregates permitted for a
model and request context. The returned maps are immutable snapshots.

```ruby
info = Scry.filter_capabilities(model: User, context: current_user)

info[:properties]
# [{ key: "first_name", label: "First name", type: "string" }, ...]

info[:property_predicates]
# { first_name: [:eq, :not_eq, :matches], active: [:eq_true, :eq_false] }

info[:associations]
# [{ key: "emails", label: "Emails" }, ...]
```

`Model.filter_capabilities(context, locale:)` returns the same schema. Pass a
locale to localize predicate, property, and association labels.

## Contents

- [Schema](#schema)
- [Aggregate discovery](#aggregate-discovery)
- [Errors and cache invalidation](#errors-and-cache-invalidation)

## Schema

The top-level keys are:

| Key | Contents |
| --- | --- |
| `properties` | Allowed concrete and custom properties with key, label, and logical type |
| `associations` | Allowed associations and their labels/metadata |
| `predicates` | General predicate metadata |
| `property_predicates` | Allowed predicates per property |
| `order` | Allowed order properties |
| `association_targets` | Allowed concrete targets for polymorphic associations |
| `aggregates` | Existing aggregate permission map |
| `aggregate_metadata` | Aggregate labels, result types, adapter and empty-set metadata |
| `aggregate_predicates` | Allowed predicates per aggregate or aggregate property |

General predicate metadata includes its label, declared type groups,
`applies_to` filter kinds, ordered parameter metadata, and argument arity:

```ruby
info[:predicates][:eq]
# {
#   label: "equals",
#   types: ["numerical", "textual", ...],
#   applies_to: [:property, :computed, :aggregate],
#   parameters: [{ name: :value, kind: :required }],
#   arguments: { min: 1, max: 1 }
# }
```

`types` and `applies_to` let an expression editor determine whether a
predicate fits a logical result type and filter kind. `max: nil` means the
registered callback accepts an unbounded rest argument.

## Aggregate discovery

Fixed-result aggregates expose one predicate list:

```ruby
info[:aggregate_metadata]["emails"]["count"]
# { label: "count", result_type: "integer", property: false,
#   types: ["all"], distinct: true, empty_value: 0, adapters: nil }

info[:aggregate_predicates]["emails"]["count"]
# [:eq, :gteq, ...]
```

Property-result aggregates expose metadata and predicates per permitted child
property:

```ruby
info[:aggregate_metadata]["emails"]["min"][:result_types]
# { "address" => "string", ... }

info[:aggregate_predicates]["emails"]["min"]["address"]
# [:eq, :matches, ...]
```

These maps respect context, adapter restrictions, aggregate permissions, and
child-property permissions. Empty predicate lists mean that no comparison is
permitted for that aggregate or property.

Aggregate labels respect `locale`. Aggregate `types` retain declared registry groups, while `result_types` resolves a property-result aggregate for each permitted property. General predicate metadata also includes aggregate-only comparisons. Change definitions through registration and permission APIs.

## Errors and cache invalidation

Models without `Scry::Filterable`, invalid model arguments, and ordinary
discovery failures return empty metadata with `error: true`. Permission
callback failures follow `callback_error_policy`. `NameError` and configured
filter errors remain observable to the caller. The empty schema contains empty
`properties`, `associations`, `predicates`, `property_predicates`, `order`,
`association_targets`, `aggregates`, `aggregate_metadata`, and
`aggregate_predicates` collections alongside `error: true`.

Changing a filterable model's attributes, table name, or schema information
invalidates discovery caches. Call `reset_column_information` after schema
changes, as required by Active Record. Permission caches are thread-local and
the Rails integration clears them through request middleware and preparation
hooks.

[Back to the README](../README.md#building-a-filter-ui)
