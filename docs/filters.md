# Filter reference

See the [README](../README.md#building-filters) for everyday examples. A top-level filter may be a property, group, association, aggregate, computed, or registered custom filter. Use a group to combine conditions.

## Contents

- [Property filters](#property-filters)
- [Group filters](#group-filters)
- [Association filters](#association-filters)
- [Aggregate filters](#aggregate-filters)
- [Computed filters](#computed-filters)
- [Custom boolean properties](#custom-boolean-properties)
- [Negation](#negation)

## Property filters

Property filters compare a column value against a predicate.

```ruby
{ type: "property", property: "first_name", predicate: "eq", args: ["Alice"] }
```

| Key | Required | Type | Description |
|-----|----------|------|-------------|
| `type` | Yes | `"property"` | Filter type identifier |
| `property` | Yes | String | Column name or custom property filter name |
| `predicate` | Yes | String | Predicate name (see [Built-in predicates](predicates.md)) |
| `args` | Conditional | Array | Positional predicate arguments (omit or use `[]` for zero-param predicates) |
| `negate` | No | Boolean | Invert the result |

**Examples:**

```ruby
# Exact match
{ type: "property", property: "first_name", predicate: "eq", args: ["Alice"] }

# Text search (LIKE %value%)
{ type: "property", property: "first_name", predicate: "matches", args: ["ali"] }

# Numeric range
{ type: "property", property: "age", predicate: "between", args: [18, 65] }

# Boolean
{ type: "property", property: "active", predicate: "eq_true" }

# NULL check
{ type: "property", property: "deleted_at", predicate: "eq_nil" }

# Temporal range (ISO 8601 duration)
{ type: "property", property: "created_at", predicate: "within", args: ["P7D"] }
```

## Group filters

Group filters combine child filters with `and` (all must match) or `or` (any must match).

```ruby
{
  type: "group",
  predicate: "and",  # or "or"
  filters: [
    # child filters here
  ]
}
```

| Key | Required | Type | Description |
|-----|----------|------|-------------|
| `type` | Yes | `"group"` | Filter type identifier |
| `predicate` | Yes | `"and"` or `"or"` | Logical operator (case-insensitive) |
| `filters` | Yes | Array | Child filter hashes |
| `negate` | No | Boolean | Invert the result |

Groups can be nested to express complex logic:

```ruby
# (active = true) AND (first_name LIKE 'A%' OR first_name LIKE 'B%')
{
  type: "group",
  predicate: "and",
  filters: [
    { type: "property", property: "active", predicate: "eq_true" },
    {
      type: "group",
      predicate: "or",
      filters: [
        { type: "property", property: "first_name", predicate: "starts_with", args: ["A"] },
        { type: "property", property: "first_name", predicate: "starts_with", args: ["B"] }
      ]
    }
  ]
}
```

**Empty group semantics:**
- Empty `and` group returns all records (identity element)
- Empty `or` group returns no records (annihilator)

## Association filters

Association filters query records through their relationships.

```ruby
{ type: "association", association: "emails", predicate: "has_any", args: [[1, 2, 3]] }
```

| Key | Required | Type | Description |
|-----|----------|------|-------------|
| `type` | Yes | `"association"` | Filter type identifier |
| `association` | Yes | String | Association name on the model |
| `predicate` | Yes | String | Association predicate name |
| `args` | Conditional | Array | One candidate-set argument, such as `[[1, 2]]` or `[Email.where(...)]` |
| `scoping` | No | Hash | Group filter applied to the associated model before evaluation |
| `target_type` | No | String | Required token for a registered polymorphic association target |
| `negate` | No | Boolean | Invert the result |

**Available association predicates:**

| Predicate | Description | Supports |
|-----------|-------------|----------|
| `has_any` | Has at least one of the specified records | All association types |
| `not_has_any` | Does not have any of the specified records | All association types |
| `has_all` | Has every one of the specified records | has_many, HABTM |
| `not_has_all` | Does not have all of the specified records | has_many, HABTM |
| `only_has_any` | Only has records from the specified set (no others) | has_many, HABTM |
| `only_has_all` | Has exactly the specified set and nothing else | has_many, HABTM |

**Empty array semantics:**
- `has_any([])` returns no records (vacuous falsehood)
- `has_all([])` returns all records (vacuous truth)
- `only_has_all([])` returns all records (vacuous truth)

**Scoping** lets you filter associated records before applying the predicate:

```ruby
# Users who have at least one email with an @example.com address
{
  type: "association",
  association: "emails",
  predicate: "has_any",
  scoping: {
    type: "group",
    predicate: "and",
    filters: [
      { type: "property", property: "address", predicate: "ends_with", args: ["@example.com"] }
    ]
  }
}
```

### Advanced association queries

Ruby callers can supply an ActiveRecord relation or an Arel select manager as the candidate set.
DISTINCT relations must expose the associated model's primary key under its original column name.
For example, `Email.select(:id, :address).distinct` is supported; `Email.select(:address).distinct` is rejected during compilation.
Ordinary relations still select the primary key before pagination and deduplication.
Raw Arel candidates must select exactly one column: the primary key under its original name.
Use explicit Arel attributes for complex SQL projections whose output names cannot be established from simple identifiers.
Invalid projections follow the configured invalid-filter policy: `:skip` preserves valid siblings, `:raise` raises,
and `:match_none` returns an empty relation.
Derived sources must also expose the canonical primary key, including through nested aliases.
Grouped candidate relations and grouped custom-filter results must group by their model's primary key before membership projection.
The caller's root grouping and projection remain unchanged when no membership projection is required.

Association scopes with `limit` or `offset` are selected independently for each owner, using the association's
ordering and a stable primary-key tie breaker. This includes ordered `has_one` associations, composite parent keys,
through associations, and self-referential associations. Nested `scoping` is applied after the association rows are
selected, so filtering `latest_payments` by `status: "failed"` does not match an older failed payment when the latest
payment is paid. Owner-dependent Ruby callbacks cannot be translated into this set-based query and are rejected.

The association order may use host-built Arel expressions, including attributes, arithmetic, aggregates, named
functions, and `NULLS FIRST` or `NULLS LAST` wrappers. Scry translates those expression trees onto the
ranked relation used for the per-owner window; it does not parse arbitrary SQL order strings. Unmapped attributes,
raw SQL literals, and window or subquery order nodes are rejected with `FilterError`. When an association scope is
`distinct`, duplicate joined rows are removed before the per-owner offset and limit are ranked.

For polymorphic associations, register static targets during boot and pass the registered token in the filter:

```ruby
Comment.add_filter_targets(:commentable, post: Post, photo: Photo)

{
  type: "association", association: "commentable", target_type: "post",
  predicate: "has_any", args: [[post.id]]
}
```

## Aggregate filters

Aggregate filters apply SQL aggregate functions (COUNT, SUM, AVG, MIN, MAX) to associated records and filter on the result using a HAVING clause.

```ruby
{ type: "aggregate", association: "emails", aggregate: "count", predicate: "gteq", args: [3] }
```

| Key | Required | Type | Description |
|-----|----------|------|-------------|
| `type` | Yes | `"aggregate"` | Filter type identifier |
| `association` | Yes | String | Association name on the model |
| `aggregate` | Yes | String | `"count"`, `"sum"`, `"avg"`, `"min"`, or `"max"` |
| `predicate` | Yes | String | Numerical predicate for the HAVING clause |
| `args` | Conditional | Array | Positional comparison arguments; `between` and `not_between` use `[low, high]` |
| `property` | Conditional | String | Column on the associated model (required for sum/avg/min/max, not for count) |
| `distinct?` | No | Boolean | Apply DISTINCT to the aggregate (default: false) |
| `scoping` | No | Hash | Group filter applied to the associated model before aggregating |
| `negate` | No | Boolean | Invert the result |

**Examples:**

```ruby
# Users with more than 5 emails
{ type: "aggregate", association: "emails", aggregate: "count", predicate: "gt", args: [5] }

# Users whose emails total at least 1 MiB (assuming Email has a size_bytes column)
{
  type: "aggregate",
  association: "emails",
  aggregate: "sum",
  property: "size_bytes",
  predicate: "gteq",
  args: [1_048_576]
}

# Users with zero emails
{
  type: "aggregate",
  association: "emails",
  aggregate: "count",
  predicate: "eq",
  args: [0]
}

# Count emails matching a condition
{
  type: "aggregate",
  association: "emails",
  aggregate: "count",
  predicate: "gteq",
  args: [2],
  scoping: {
    type: "group",
    predicate: "and",
    filters: [
      { type: "property", property: "address", predicate: "ends_with", args: ["@example.com"] }
    ]
  }
}
```

`COUNT` evaluates an owner with no matching associated rows as `0`, including after association scoping. `SUM`, `AVG`, `MIN`, and `MAX` retain SQL `NULL` for empty sets unless a host registers a custom aggregate with an explicit `empty_value`.

Integer-result aggregates such as COUNT reject fractional comparison values rather than truncating them.
This applies to numeric operands, numeric strings, and range bounds. Integral numeric values remain supported.


## Computed filters

Computed filters apply a predicate to a safe arithmetic expression. An
expression is a property reference, a finite numeric literal, or a binary
`add`, `subtract`, `multiply`, or `divide` node. Every operator requires exactly
two operands; arbitrary SQL nodes are not accepted.

```ruby
{
  type: "computed",
  expression: {
    operator: "subtract",
    operands: [{ property: "age" }, { literal: 1 }]
  },
  predicate: "gteq",
  args: [18]
}
```

Nested expressions and literals are valid:

```ruby
{
  type: "computed",
  expression: {
    operator: "multiply",
    operands: [
      { operator: "subtract", operands: [{ property: "age" }, { literal: 1 }] },
      { literal: 2 }
    ]
  },
  predicate: "eq",
  args: [38]
}
```

Supported expression properties must be permitted by the model. A computed
predicate must be registered with `applies_to: [:computed]` (or include that
kind), and every property leaf contributes its own predicate permission. A
literal-only expression does not bypass predicate permissions.

Division by a literal zero is rejected. Division uses `NULLIF` and adapter
specific casts so fractional results remain fractional on PostgreSQL and
SQLite. Computed expressions work against an aliased derived source when the
incoming relation exposes the selected source correctly.

Computed predicates use the shared argument validation and formatting pipeline,
with diagnostics and callback error policies. Their transforms use the `:computed`
property key. The expression result type is the referenced property's type, or
numeric for literals and arithmetic operators.


## Custom boolean properties

Register a named condition as a custom property when the condition should be exposed as a boolean choice:

```ruby
User.add_custom_property_filter(type: :boolean, label: "VIP customer") do
  {
    vip: {
      type: "group",
      predicate: "and",
      filters: [
        { type: "property", property: "first_name", predicate: "eq", args: ["Ada"] }
      ]
    }
  }
end
```

The `type` may be omitted or set to `:boolean` or `"boolean"`. The condition has exactly two predicates:
`eq_true` applies the registered condition and `eq_false` applies its inverse. Both predicates take no arguments.
Set `predicates: []` to expose the property while denying both predicates, or provide a subset such as
`predicates: [:eq_true]`. Other type names and value-taking predicates are rejected. For numeric expressions or
comparisons with operands, use a `computed` filter or an aggregate/property filter instead of a custom property.

Named callbacks are also supported when a model method returns the same property-to-filter hash:

```ruby
User.add_custom_property_filter :vip_filters, type: "boolean"
```

## Negation

Any filter can be negated by adding `negate: true`. This inverts the filter's result.

```ruby
# Users whose first name is NOT "Alice"
{ type: "property", property: "first_name", predicate: "eq", args: ["Alice"], negate: true }

# Users who do NOT have any of these emails
{ type: "association", association: "emails", predicate: "has_any", args: [[1, 2]], negate: true }
```

Negation wraps the filter condition with `NOT`. Complex relation conditions become primary-key membership subqueries before negation. The caller scope remains outside this inversion.
