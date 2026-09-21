# Scry

Extensible ActiveRecord filtering with a JSON DSL, type-safe predicates, and fine-grained permissions.

Scry translates JSON filter definitions into optimized ActiveRecord queries. It supports property, association, aggregate, and group filters with permission-controlled access per model, per attribute, and per predicate.

## Features

- **JSON-driven filtering** - Build complex queries from declarative filter hashes (ideal for API-driven UIs)
- **4 filter types** - Property, association, aggregate, and group filters compose into arbitrary query trees
- **40+ built-in predicates** - Equality, comparison, text matching, temporal ranges, boolean, network, array, and range predicates
- **Layered permission system** - Whitelist, blacklist, includelist, and excludelist chains with context-aware evaluation
- **Aggregate queries** - COUNT, SUM, AVG, MIN, MAX with scoped membership subqueries and zero-inclusive comparisons
- **Transform pipeline** - Per-property attribute, value, and value-node transforms with predicate-specific targeting
- **Type hierarchy** - Predicates and aggregates organized into extensible type groups with transitive closure
- **I18n support** - Translated labels for predicates, properties, and associations
- **Thread-safe caching** - LRU-evicted, thread-local permission caches with automatic Rack middleware cleanup
- **Rails integration** - Optional Railtie integration for middleware and i18n; Arel extensions are opt-in

## Table of contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Filter format](#filter-format)
  - [Group filters](#group-filters)
  - [Property filters](#property-filters)
  - [Association filters](#association-filters)
  - [Aggregate filters](#aggregate-filters)
  - [Negation](#negation)
- [Built-in predicates](#built-in-predicates)
- [Permissions](#permissions)
  - [Property permissions](#property-permissions)
  - [Association permissions](#association-permissions)
  - [Predicate permissions](#predicate-permissions)
  - [Aggregate permissions](#aggregate-permissions)
  - [Model-level permissions](#model-level-permissions)
  - [Context-based permissions](#context-based-permissions)
  - [Strict mode](#strict-mode)
- [Custom predicates](#custom-predicates)
- [Custom aggregates](#custom-aggregates)
- [Transforms](#transforms)
- [Type system](#type-system)
- [Configuration](#configuration)
- [I18n](#i18n)
- [Caching](#caching)
- [Custom filter classes](#custom-filter-classes)
- [Rails integration](#rails-integration)
- [Requirements](#requirements)
- [License](#license)

## Installation

Add the gem to your Gemfile:

```ruby
gem "rails_scry"
```

Then run:

```bash
bundle install
```

Scry requires ActiveRecord and ActiveSupport. Rails and Railties are optional: requiring the gem after
`active_record` is enough for standalone ActiveRecord applications. In a Rails application, the Railtie is loaded
automatically when Rails is already loaded.

For standalone ActiveRecord applications, install the adapter separately and require ActiveRecord before the gem:

```ruby
require "active_record"
require "rails_scry"
```

The gem does not modify `Arel::Predications` during a standalone boot. Applications that intentionally use the
compatibility helpers can opt in explicitly. Built-in DSL association predicates use the local association attribute
behavior and do not require this global installation:

```ruby
Scry.install_arel_extensions!
```

## Quick start

### 1. Include `Filterable` in your models

```ruby
class ApplicationRecord < ActiveRecord::Base
  include Scry::Filterable
  primary_abstract_class
end
```

All models inheriting from `ApplicationRecord` can now be filtered. Permissions are inherited and can be customized per model.

### 2. Filter records

```ruby
filter = {
  type: "group",
  predicate: "and",
  filters: [
    { type: "property", property: "first_name", predicate: "eq", args: ["Alice"] },
    { type: "property", property: "active", predicate: "eq_true" }
  ]
}

result = Scry.filter_records_by(
  records: User.all,
  filter:  filter,
  context: current_user
)
users = result.relation
# => ActiveRecord::Relation with matching records
```

### 3. Query available filters

Use `filter_capabilities` to discover what filters are allowed for a model and context. This is useful for building dynamic filter UIs.

```ruby
info = Scry.filter_capabilities(model: User, context: current_user)

info[:properties]
# => [{ key: "first_name", label: "First name", type: "string" }, ...]

info[:associations]
# => [{ key: "emails", label: "Emails" }, ...]

info[:predicates]
# => { eq: { label: "equals", types: ["numerical", "textual", ...],
#            applies_to: [:property, :computed, :aggregate],
#            parameters: [{ name: :value, kind: :required }],
#            arguments: { min: 1, max: 1 } }, ... }

info[:property_predicates]
# => { first_name: [:eq, :not_eq, :matches, ...], active: [:eq_true, :eq_false], ... }

info[:aggregates]
# => { "emails" => { "count" => true }, ... }
```

Aggregate discovery preserves the existing `aggregates` permission map and adds two fields:

```ruby
info[:aggregate_metadata]["emails"]["count"]
# => { label: "count", result_type: "integer", property: false,
#      types: ["all"], distinct: true, empty_value: 0, adapters: nil }

info[:aggregate_predicates]["emails"]["count"]
# => [:eq, :gteq, ...]

info[:aggregate_metadata]["emails"]["min"][:result_types]
# => { "address" => "string", ... }

info[:aggregate_predicates]["emails"]["min"]["address"]
# => [:eq, :matches, ...]
```

Fixed-result aggregates expose one predicate list. Property-result aggregates expose a list for each permitted property, plus its resolved result type. Aggregate labels respect `locale`; general `predicates` metadata includes the labels, declared type groups, applicability, and arities of aggregate-only comparisons. The `types` and `applies_to` fields in general predicate metadata tell a computed-expression editor which logical types and filter kinds a predicate accepts; aggregate `types` likewise remain the declared registry groups, while `result_types` resolves a property-result aggregate per selected property. These maps respect context, adapter, and child-property permissions. Empty predicate lists mean no comparison is permitted for that aggregate or property.

`Model.filter_capabilities` returns the same schema. Permission and metadata maps are immutable snapshots; change declarations through registration and permission APIs.

Models without `Scry::Filterable` return empty discovery metadata with `error: true`. The discovery API
reports ordinary failures in that metadata; permission callback failures follow `callback_error_policy`.

### 4. Use in a controller

```ruby
class UsersController < ApplicationController
  def index
    filter = params.require(:filter).permit!.to_h

    result = Scry.filter_records_by(
      records: User.where(organisation: current_organisation),
      filter:  filter,
      context: current_user
    )
    @users = result.relation
  end

  def filter_options
    render json: Scry.filter_capabilities(
      model:   User,
      context: current_user,
      locale:  I18n.locale
    )
  end
end
```

## Filter format

`filter_records_by` accepts a group, property, association, aggregate, computed, or registered custom filter at the top level. Use a group when multiple filters must compose.

### Group filters

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

### Property filters

Property filters compare a column value against a predicate.

```ruby
{ type: "property", property: "first_name", predicate: "eq", args: ["Alice"] }
```

| Key | Required | Type | Description |
|-----|----------|------|-------------|
| `type` | Yes | `"property"` | Filter type identifier |
| `property` | Yes | String | Column name or custom property filter name |
| `predicate` | Yes | String | Predicate name (see [Built-in predicates](#built-in-predicates)) |
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

#### Custom boolean properties

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

### Association filters

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

### Aggregate filters

Aggregate filters apply SQL aggregate functions (COUNT, SUM, AVG, MIN, MAX) to associated records and filter on the result using a HAVING clause.

Integer-result aggregates such as COUNT reject fractional comparison values rather than truncating them.
This applies to numeric operands, numeric strings, and range bounds. Integral numeric values remain supported.

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

# Technicians with total travel time >= 120 minutes
{
  type: "aggregate",
  association: "schedule_assignments",
  aggregate: "sum",
  property: "travel_time_minutes",
  predicate: "gteq",
  args: [120]
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

### Negation

Any filter can be negated by adding `negate: true`. This inverts the filter's result.

```ruby
# Users whose first name is NOT "Alice"
{ type: "property", property: "first_name", predicate: "eq", args: ["Alice"], negate: true }

# Users who do NOT have any of these emails
{ type: "association", association: "emails", predicate: "has_any", args: [[1, 2]], negate: true }
```

Negation wraps the filter condition with `NOT`. Complex relation conditions become primary-key membership subqueries before negation. The caller scope remains outside this inversion.

## Built-in predicates

### Global

Available on most column types.

| Predicate | Params | SQL | Example value |
|-----------|--------|-----|---------------|
| `eq` | 1 | `= value` | `"Alice"` |
| `not_eq` | 1 | `!= value` | `"Alice"` |
| `eq_nil` | 0 | `IS NULL` | *(none)* |
| `not_eq_nil` | 0 | `IS NOT NULL` | *(none)* |

`eq` and `not_eq` auto-generate compound variants: `eq_any`, `eq_all`, `not_eq_any`, `not_eq_all`.

### Numerical

For integer, float, decimal, and temporal columns.

| Predicate | Params | SQL | Example value |
|-----------|--------|-----|---------------|
| `gt` | 1 | `> value` | `100` |
| `lt` | 1 | `< value` | `100` |
| `gteq` | 1 | `>= value` | `100` |
| `lteq` | 1 | `<= value` | `100` |
| `between` | 2 | `BETWEEN low AND high` | `[18, 65]` |
| `not_between` | 2 | `NOT BETWEEN low AND high` | `[18, 65]` |

For `between` and `not_between`, pass a two-element array `[low, high]`. The gem auto-sorts if low > high.

### Temporal

For date, time, datetime, and timestamp columns. Values are [ISO 8601 duration](https://en.wikipedia.org/wiki/ISO_8601#Durations) strings.

| Predicate | Params | Description | Example value |
|-----------|--------|-------------|---------------|
| `within` | 1 | Between `duration.ago` and `duration.since` | `"P7D"` |
| `within_next` | 1 | Between now and `duration.since` | `"P30D"` |
| `within_previous` | 1 | Between `duration.ago` and now | `"PT12H"` |
| `not_within` | 1 | Outside `duration.ago` to `duration.since` | `"P1Y"` |
| `not_within_next` | 1 | Before now or after `duration.since` | `"P7D"` |
| `not_within_previous` | 1 | Before `duration.ago` or after now | `"P7D"` |

**Duration format examples:** `"P1D"` (1 day), `"P7D"` (7 days), `"PT2H"` (2 hours), `"P1M"` (1 month), `"P1Y"` (1 year), `"P1Y6M"` (1 year 6 months).

### Textual

For string, text, and enum columns. Values are automatically escaped for SQL LIKE.

| Predicate | Params | SQL | Example value |
|-----------|--------|-----|---------------|
| `matches` | 1 | `LIKE '%value%'` | `"alice"` |
| `starts_with` | 1 | `LIKE 'value%'` | `"ali"` |
| `ends_with` | 1 | `LIKE '%value'` | `"ice"` |
| `does_not_match` | 1 | `NOT LIKE '%value%'` | `"alice"` |
| `does_not_start_with` | 1 | `NOT LIKE 'value%'` | `"ali"` |
| `does_not_end_with` | 1 | `NOT LIKE '%value'` | `"ice"` |

All textual predicates auto-generate compound variants (`matches_any`, `matches_all`, etc.).

> **Note:** Regexp predicates (`matches_regexp`, `does_not_match_regexp`) are not registered by default for security. Register them manually if needed.

### Boolean

For boolean columns.

| Predicate | Params | SQL |
|-----------|--------|-----|
| `eq_true` | 0 | `= true` |
| `eq_false` | 0 | `= false` |

### JSON

For json/jsonb columns.

| Predicate | Params | SQL |
|-----------|--------|-----|
| `contains` | 1 | `@>` (PostgreSQL containment) |

### PostgreSQL: Network

For inet and cidr columns.

| Predicate | Params | Operator | Description |
|-----------|--------|----------|-------------|
| `inet_contains` | 1 | `>>` | Network contains address |
| `inet_contained_within` | 1 | `<<` | Address is within network |
| `inet_overlaps` | 1 | `&&` | Networks overlap |

### PostgreSQL: Array

For PostgreSQL array columns.

| Predicate | Params | Operator | Description |
|-----------|--------|----------|-------------|
| `array_contains` | 1 | `@>` | Array contains all elements |
| `array_contained_by` | 1 | `<@` | Array is subset of value |
| `array_overlaps` | 1 | `&&` | Arrays share elements |

### PostgreSQL: Range

For PostgreSQL range columns (daterange, tsrange, int4range, etc.).

| Predicate | Params | Operator | Description |
|-----------|--------|----------|-------------|
| `range_contains` | 1 | `@>` | Range contains value |
| `range_contained_by` | 1 | `<@` | Range is within value |
| `range_overlaps` | 1 | `&&` | Ranges overlap |
| `range_strictly_left_of` | 1 | `<<` | Range is left of value |
| `range_strictly_right_of` | 1 | `>>` | Range is right of value |
| `range_adjacent_to` | 1 | `-\|-` | Range is adjacent to value |

### Compound variants

Predicates registered with `compounds: true` opt in to generated `_any` and `_all` variants:

- `eq_any` - matches if the value equals **any** element in the array
- `eq_all` - matches if the value equals **all** elements in the array (useful with transforms)

```ruby
# Users named "Alice" OR "Bob" (eq_any)
{ type: "property", property: "first_name", predicate: "eq_any", args: [["Alice", "Bob"]] }
```

Association and boolean predicates do not generate compounds.

## Permissions

Scry uses a layered permission system with four list types that can be chained together.

| List type | Behavior |
|-----------|----------|
| `includelist` | Add items to the allowed set (constrained by the universe of valid items) |
| `excludelist` | Remove items from the allowed set |
| `whitelist` | Replace the allowed set with the intersection of current and specified items |
| `blacklist` | Remove items from the allowed set |

Predicate permissions use specificity: global rules apply first, type rules apply next, and property rules apply last.
This order does not depend on declaration order across those categories. Within a category, rules retain declaration order.
Type rules apply ancestor groups before descendant groups. Equal or unrelated type groups retain declaration order.
A more specific `includelist` can restore a predicate removed by a broader rule.
Adapter restrictions and valid predicate types remain hard constraints after permission rules.
Other permission chains, such as properties and associations, apply rules in declaration order.

Ordering uses the same permission API:

```ruby
Invoice.add_filter_permission(:order, list_type: :whitelist) { [:created_at, :total] }
```

Polymorphic associations require an explicit application allowlist. Register target models during boot;
discovery exposes only targets allowed for the current context:

```ruby
Comment.add_filter_targets(:commentable, post: Post, photo: Photo)
```

**Default behavior:** Without any permissions configured, all model columns and associations are filterable with all applicable predicates. Use permissions to restrict access.

Permissions declared on a model are copied to Active Record subclasses when the subclass is created. The subclass can
then add rules or reset one permission chain without changing its parent or sibling classes:

```ruby
class AdminUser < User
  reset_filter_permissions(:properties)
  add_filter_permission(:properties, list_type: :whitelist) { |_context| [:email, :role] }
end
```

Rules within a chain are evaluated in declaration order. `includelist` adds capabilities, `excludelist` and `blacklist`
remove them, and `whitelist` intersects the current set. Predicate permissions additionally apply broader rules before
more specific type and property rules, so a specific `includelist` can restore a predicate removed by a broader rule.
Each callback receives the same request context used for discovery and filtering.

### Property permissions

Control which columns users can filter on.

```ruby
class User < ApplicationRecord
  # Only allow filtering on these properties
  add_filter_permission(:properties, list_type: :whitelist) do |context|
    [:first_name, :last_name, :active, :created_at]
  end
end
```

```ruby
class User < ApplicationRecord
  # Block sensitive columns
  add_filter_permission(:properties, list_type: :blacklist) do |context|
    [:encrypted_password, :reset_password_token]
  end
end
```

### Association permissions

Control which associations users can filter through.

```ruby
class User < ApplicationRecord
  add_filter_permission(:associations, list_type: :whitelist) do |context|
    [:emails, :organisation]
  end
end
```

The gem automatically excludes associations whose target model returns `false` from `model_allowed?`.

### Predicate permissions

Control which predicates are available, either by type group or by property.

**By type group** (applies to all properties of that type):

```ruby
class User < ApplicationRecord
  # Remove LIKE predicates from all textual columns
  add_filter_permission(:type_predicates, list_type: :excludelist) do |context|
    { textual: [:matches, :starts_with, :ends_with] }
  end
end
```

**By property** (overrides type-level permissions for a specific property):

```ruby
class User < ApplicationRecord
  # Only allow exact match on email
  add_filter_permission(:property_predicates, list_type: :whitelist) do |context|
    { email: [:eq, :not_eq] }
  end
end
```

### Aggregate permissions

Control which aggregate functions are allowed on which associations.

```ruby
class User < ApplicationRecord
  # Only allow COUNT on emails, SUM on specific columns
  add_filter_permission(:aggregates, list_type: :whitelist) do |context|
    {
      emails: { count: true },
      orders: { count: true, sum: [:total_amount] }
    }
  end
end
```

Values can be:
- `true` - aggregate allowed on all columns
- Array of column names - aggregate allowed only on those columns
- `:all` - same as `true`

### Model-level permissions

Allow or deny filtering on an entire model.

```ruby
class InternalAuditLog < ApplicationRecord
  add_model_permission do |context|
    context.respond_to?(:admin?) && context.admin?
  end
end
```

The block should return `true` (allow), `false` (deny), or `nil` (default allow). A denied model produces a failed result with an empty relation and a redacted diagnostic. Use `add_model_permission` for this boolean gate; generic `add_filter_permission(:model, list_type: ...)` is rejected because list policies do not apply to model-level decisions.

### Mandatory model scopes

Use a model scope to define the rows the filtering engine can examine. The block receives the filtering context and must return an `ActiveRecord::Relation` for the same model.

```ruby
class Comment < ApplicationRecord
  add_filter_scope do |current_user|
    user_can_read(current_user)
  end
end
```

You can also register a named callback when the host needs to share its policy method:

```ruby
class Comment < ApplicationRecord
  add_filter_scope :readable_by_context

  def self.readable_by_context(current_user)
    user_can_read(current_user)
  end
end
```

Scopes inherit. Multiple scopes intersect with the caller relation by the complete primary key. The engine applies target and through-model scopes before association limits, membership checks, aggregates, and negation. Pass the context to `filter_records_by`; the engine passes it to every scope callback.

A scope callback that raises, returns `nil`, or returns a relation for another model fails closed. `:skip` returns a failed result with an empty relation, while `:raise` raises `Scry::FilterError` and `:match_none` returns a failed empty relation. Native Arel used directly by a host has no context. A context-required scope therefore fails closed there. Custom filters must use the supplied filter interfaces and cannot use direct SQL to bypass host authorization.

### Context-based permissions

The `context` parameter flows through all permission evaluations. Use it to implement role-based access control.

```ruby
class User < ApplicationRecord
  add_filter_permission(:properties, list_type: :whitelist) do |context|
    base = [:first_name, :last_name, :active]
    base += [:email, :phone] if context&.admin?
    base
  end

  add_filter_permission(:associations, list_type: :whitelist) do |context|
    context&.admin? ? [:emails, :organisation, :account] : [:emails]
  end
end
```

### Strict mode

In strict mode, properties, associations, predicates, and aggregates start empty. Use `includelist` to grant each required capability.

```ruby
Scry.configure do |config|
  config.strict = true
end
```

With strict mode enabled:
- Properties start empty (no columns exposed)
- Associations start empty
- Predicates start empty
- Aggregates start empty

A `whitelist` only intersects the current set. It cannot add capabilities to an empty set.
For example, grant one property and its equality predicate:

```ruby
class User < ApplicationRecord
  add_filter_permission(:properties, list_type: :includelist) { |_context| [:first_name] }
  add_filter_permission(:property_predicates, list_type: :includelist) do |_context|
    { first_name: [:eq] }
  end
end
```

Model permission remains a separate gate. The model is allowed unless its model rule denies access.

## Custom predicates

Register new predicates to extend the filtering vocabulary.

Custom predicates apply to property filters by default. Set `applies_to` when a predicate is intended for computed,
aggregate, or association filters; the same declaration controls execution and discovery. Valid kinds are
`:property`, `:computed`, `:aggregate`, and `:association`.

### Using an Arel predicate method

Prefer an Arel predicate method when the operation is useful outside filter
payloads. This keeps the SQL operation reusable for ordinary Arel queries and
lets the filter registry provide discovery and validation around it.

```ruby
Scry.configure do |config|
  config.register_predicate(:not_eq,
    types: [:textual, :numerical],
    applies_to: %i[property association computed aggregate]
  )
  # Delegates to Arel::Predications#not_eq
end
```

### Using a custom block

```ruby
Scry.configure do |config|
  config.register_predicate(:case_insensitive_eq,
    types: [:textual],
    applies_to: [:property, :computed],
    compounds: false
  ) do |attr, value|
    Arel::Nodes::NamedFunction.new('LOWER', [attr])
      .eq(Arel::Nodes::NamedFunction.new('LOWER', [Arel::Nodes.build_quoted(value)]))
  end
end
```

### Association predicates can use Arel methods

Association predicates dispatch through the ordinary Arel attribute API. The
attribute carries a per-instance association behavior object, so a host-defined
Arel method can recover the current `AssociationQuery` context with
`AssociationQuery.for_attribute`. The behavior preserves the owner relation,
child scoping, authorization context, aliases, and polymorphic target selected
for the current filter evaluation.
For a zero-operand association predicate, `AssociationQuery#eligible_child_relation`
returns the child relation selected by the filter's current association scope;
the gem does not add an implicit operand to your callback.

```ruby
module Arel::Predications
  def has_at_least_two(value)
    query = Scry::AssociationQuery.for_attribute(self)
    query.owner_count_at_least(value, minimum: 2)
  end

  def has_matching_child(value)
    Scry::AssociationQuery.for_attribute(self)
      .owner_child_predicate(:matches, value)
  end
end

Scry.configure do |config|
  config.register_predicate(:has_at_least_two,
    types: [:many_association], applies_to: [:association], compounds: false
  ) { |attribute, value| attribute.has_at_least_two(value) }
  config.register_predicate(:has_matching_child,
    types: [:many_association], applies_to: [:association], compounds: false
  ) { |attribute, value| attribute.has_matching_child(value) }
end

# Filter payload use:
{ type: :association, association: :emails, predicate: :has_at_least_two,
  args: [[email_id]] }
```

`matching`, `owner_membership`, `has_any`, `has_all`, `only_has_any`, and
`only_has_all` are public `AssociationQuery` primitives. Extensions should
obtain the query through `for_attribute` instead of constructing it.
`owner_child_predicate` is available when an extension needs to express a
child-column predicate as owner membership, so the extension remains
independent of the child model's identity shape. For custom cardinality
logic, compose the same public primitives and plural identity accessors:

```ruby
rows = query.matching(value)
query.owner_membership(
  rows.group(*query.parent_keys).having(Arel.star.count.gteq(2))
)
```

Use this lower-level `Arel.star.count` form only when the built-in
`owner_count_at_least` does not express the required cardinality rule.
`owner_count_at_least` accepts an integer minimum; zero or negative minimums
use the identity predicate for the owner scope. It counts distinct complete
child identities, while aggregate `distinct` remains controlled by the
aggregate definition.

### With a validator

Validators run before the formatter. They can transform or reject values.

```ruby
Scry.configure do |config|
  config.register_predicate(:between_rounded,
    types: [:numerical],
    compounds: false,
    validator: ->(value) { Integer(value) }
  ) do |attribute, lower, upper|
    attribute.between(lower..upper)
  end
end
```

### With a formatter

Formatters transform the value after validation, before the query is built.

```ruby
Scry.configure do |config|
  config.register_predicate(:matches,
    types: [:textual],
    formatter: ->(value) { "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s)}%" }
  )
end
```

### Compound variants

`register_predicate` generates `_any` and `_all` compound variants only when
you opt in with `compounds: true`:

```ruby
Scry.configure do |config|
  config.register_predicate(:between, types: [:numerical], compounds: true)
  # Generates between_any and between_all
end
```

When a registered name wraps an existing Arel method, compounds keep the
registered name while dispatching to the Arel compound method. For example, a
`less_than` registration with `arel_predicate: :lt` exposes
`less_than_any` and `less_than_all`, and uses `lt_any` and `lt_all` to build
their conditions. The payload still uses the public registered names.

### Unregistering predicates

```ruby
Scry.configure do |config|
  config.unregister_predicate(:matches_regexp, :does_not_match_regexp)
  config.unregister_predicate_from_type(:textual, :matches)
end
```

### Extension callback contracts

Callbacks build a query or metadata. They do not run once for each matching database record.
Keep them deterministic and avoid database writes. Cached permission results can reduce invocation counts.

| Extension | Inputs | Required return | Invocation |
|-----------|--------|-----------------|------------|
| Collection permission | `context` | Array or Set of string/symbol names | Permission resolution, cached by model and context |
| Type/property predicate permission | `context` | Hash of type/property names to predicate collections or `:all` | Permission resolution |
| Model permission | `context` | `true`, `false`, or `nil` | The last registered model rule resolves the gate. `nil` allows the model |
| Custom property permission | `context` | Hash of names to group filters or metadata/filter entries | Property discovery and expansion |
| Aggregate permission | `context` | Hash of associations to aggregate permissions | Aggregate discovery and validation |
| Predicate validator | Raw value | Validated or transformed value, including `nil` | Before formatting for each filter |
| Predicate formatter | Validated value | Formatted value | After value transforms. Property filters map arrays element by element |
| Custom predicate | Arel attribute/expression, formatted Ruby operand | `Arel::Nodes::Node` | Predicate construction |
| Property transform | Operand, `context` | Replacement operand | For matching predicates at the configured transform stage |
| Aggregate builder | Associated Arel attribute, Boolean `distinct` | `Arel::Nodes::Node` | Aggregate construction |
| Custom filter class | Keyword arguments `model:`, `filter:`, `context:`, `depth:` | `#apply` returns `Scry::Result` | Each registered filter node |

Ordinary property and computed predicate callbacks receive a Ruby operand after validation and formatting.
A `value_node` transform or adapter-specific registration can deliberately make that operand an Arel node.
Filter operands are always explicit positional `args`. A predicate's registered Ruby method or callback signature determines its accepted arguments: required parameters set the minimum, optional parameters preserve their Ruby defaults when omitted, and `*rest` makes the maximum unbounded. Discovery exposes ordered `parameters` (`name` and `kind`) and `arguments` (`min` and `max`, with `max` set to `nil` for `*rest`). The gem passes `*args` exactly: `args: [[id_a, id_b]]` is one collection operand, while `args: [low, high]` is two operands. Existing arrays, sets, records, and child relations retain their shape. Aggregate comparisons receive quoted or type-normalized operands.

Most predicates receive those formatted Ruby operands unchanged. A predicate that needs type-aware Ruby operands can register `prepare_arguments: ->(args) { ... }`. It receives the complete formatted `args` array and must return an array of Ruby operands. The callback is independent of the left-hand Arel expression; the engine applies column or aggregate-result serialization and quotes the returned values afterward. Built-in predicates declare their supported filter kinds explicitly; custom predicates default to `:property`.
Use `Arel::Nodes.build_quoted` when an expression needs a quoted Ruby value. It preserves existing Arel nodes.

Validators reject input with `ArgumentError`. Other validator exceptions propagate.
Formatters, custom predicates, and aggregate builders report other `StandardError` exceptions through the configured error mode. A permission or extension callback that deliberately raises `Scry::FilterError` bypasses callback-error handling and is handled as a filter diagnostic under `invalid_filter_policy`; an unexpected exception from that callback boundary follows `callback_error_policy`. These are separate policies, and the distinction also applies when discovery reports an error.
Permission callbacks re-raise the original exception by default. With
`callback_error_policy: :match_none`, they record a redacted `:callback_error` diagnostic and the public
filtering API returns an empty relation.
A failed property transform reports an error. Under the default `invalid_filter_policy: :skip`, it retains the last
successful operand.
The default invalid-tree policy preserves that behavior. A rejecting or match-none policy applies to the complete filter after compilation.

Custom property metadata validates names, labels, the boolean type, and the accepted predicate list before discovery.
The executable expansion must be a filter hash; its nested filter shape is validated when the expansion is compiled,
so malformed definitions produce diagnostics at the custom property's filter path. Custom properties are boolean
conditions with the operand-free `eq_true` and `eq_false` predicates. Empty accepted predicate lists deny both
predicates. Named callbacks may return the same hash shape. Numeric expressions that require operands belong in
computed, aggregate, or ordinary property filters.

Zero-inclusive aggregates can evaluate comparison callbacks twice, once for existing rows and once for the empty-set expression.
The builder runs during query construction and must not depend on an invocation count.

## Custom aggregates

Register new aggregate functions beyond the built-in five. The builder receives the associated Arel attribute and
the resolved `distinct` flag. It returns the SQL expression as an Arel node.

```ruby
Scry.configure do |config|
  config.register_aggregate(
    :median,
    types: [:summable],
    result_type: :property,
    empty_value: nil,
    property: true,
    adapters: [:postgresql],
    distinct: true
  ) do |attribute, distinct|
    # Return an Arel node for the aggregate expression.
    Arel::Nodes::NamedFunction.new("MEDIAN", [attribute]).tap do |node|
      node.distinct = distinct if node.respond_to?(:distinct=)
    end
  end
  config.unregister_aggregate(:avg)
end
```

`result_type` controls which comparison predicates are available for the aggregate. Use `:property` when the
aggregate returns the associated property's type (for example, a timestamp `MIN`); `:integer` or another registered
type is appropriate for numeric results. `empty_value` defines the value used when zero-inclusive aggregation needs
an empty-set expression. Set `property: false` for aggregates such as `COUNT` that do not take a property. The
`adapters` list limits registration to named adapters such as `:postgresql`. Set `composite_distinct: true` when a
distinct aggregate must count complete composite identities rather than only the first key column; the builder still
receives the resolved Boolean `distinct` flag.

**Built-in aggregates:**

| Aggregate | Supported types | Description |
|-----------|-----------------|-------------|
| `count` | all | Count of associated records |
| `sum` | summable (integer, float, decimal) | Sum of column values |
| `avg` | summable | Average of column values |
| `min` | orderable (numerical, temporal, textual) | Minimum column value |
| `max` | orderable | Maximum column value |

## Transforms

Transforms modify how filter comparisons work at the Arel level. They apply per-property and can target different stages of the predicate pipeline.

### Transform targets

| Target | Receives | Use case |
|--------|----------|----------|
| `:attribute` | Arel attribute node | Wrap the column with SQL functions (e.g., `LOWER()`, `COALESCE()`) |
| `:value` | Raw Ruby value (pre-formatter) | Normalize user input (e.g., strip whitespace, downcase) |
| `:value_node` | Arel quoted node (post-formatter) | Wrap the value with SQL functions to match the attribute transform |

The default targets are `[:attribute, :value_node]`, which is appropriate for most SQL function wraps since both sides of the comparison must match.

### Attribute transform (case-insensitive search)

```ruby
class User < ApplicationRecord
  # Apply LOWER() to both column and value for case-insensitive comparison
  add_filter_transform(:first_name) do |node, context|
    Arel::Nodes::NamedFunction.new('LOWER', [node])
  end
end
```

### Value transform (input normalization)

```ruby
class User < ApplicationRecord
  # Strip whitespace from user-provided values before filtering
  add_filter_transform(:email, on: :value) do |value, context|
    value.to_s.strip.downcase
  end
end
```

### Predicate-specific transforms

Use `only` and `except` to target specific predicates or type groups:

```ruby
class User < ApplicationRecord
  # Apply LOWER() only for textual predicates, but not for eq/not_eq
  add_filter_transform(:last_name, only: [:textual], except: [:eq, :not_eq]) do |node, context|
    Arel::Nodes::NamedFunction.new('LOWER', [node])
  end
end
```

Transforms are ordered by specificity: predicate-specific transforms run before type-specific transforms, which run before global transforms.

### Using a class method

```ruby
class User < ApplicationRecord
  add_filter_transform(:first_name, :normalize_name_for_filter)

  def self.normalize_name_for_filter(node, context)
    Arel::Nodes::NamedFunction.new('LOWER', [node])
  end
end
```

## Type system

Predicates and aggregates are organized into type groups that form a hierarchy. When a column has type `:integer`, the gem finds all predicates registered for `:integer` and its ancestor groups (`:numerical`, `:all`).

### Default type hierarchy

```
:all
├── :numerical
│   ├── :integer
│   ├── :float
│   ├── :decimal
│   ├── :interval
│   ├── :binary
│   └── :temporal
│       ├── :date
│       ├── :time
│       ├── :datetime
│       └── :timestamp
├── :textual
│   ├── :string
│   ├── :text
│   ├── :binary
│   └── :enum
├── :boolean
├── :association
│   ├── :many_association
│   │   ├── :has_many
│   │   └── :has_and_belongs_to_many
│   └── :single_association
│       ├── :has_one
│       └── :belongs_to
├── :summable
│   ├── :integer
│   ├── :float
│   └── :decimal
├── :orderable
│   ├── :numerical
│   ├── :temporal
│   └── :textual
├── :identifier
│   ├── :uuid
│   └── :primary_key
├── :network
│   ├── :inet
│   └── :cidr
├── :array
│   ├── :string_array
│   ├── :integer_array
│   └── :text_array
├── :range
│   ├── :daterange
│   ├── :tsrange
│   ├── :tstzrange
│   ├── :int4range
│   ├── :int8range
│   └── :numrange
└── :json
```

The diagram shows registration direction (`register_types(parent, members)`).
For lookup, start at the column's concrete type and walk back to every group
that contains it, plus `:all`; overlapping groups such as `:orderable` are
therefore expected.

### Registering custom types

```ruby
Scry.configure do |config|
  # The first argument is the parent group; the remaining arguments are its members.
  config.register_types(:numerical, :currency)
  config.register_predicate(:format_currency, types: [:currency]) do |attr, value|
    # custom predicate for currency columns
  end
end
```

Type groups support transitive closure: because `:currency` is a member of
`:numerical`, a predicate registered for `:numerical` also applies to
`:currency` columns. Registering `:currency` with `:decimal` instead would make
`:decimal` a member of `:currency`; it would not make `:currency` a child of
`:numerical`.

## Configuration

```ruby
Scry.configure do |config|
  # Invalid input policy (:skip, :raise, or :match_none)
  config.invalid_filter_policy = :raise

  # Extension callback failures (:raise or :match_none)
  config.callback_error_policy = :raise

  # Diagnostic logging is independent from result policy (:silent or :warn)
  config.diagnostic_logging = :warn

  # Strict mode (default: false)
  # When true, nothing is filterable by default
  config.strict = true

  # Maximum nesting depth for group filters (default: 15)
  config.max_filter_depth = 20

  # Bounds for untrusted filter payloads (defaults: 1,000 nodes and 1 MiB)
  config.max_filter_nodes = 2_000
  config.max_filter_bytes = 2 * 1024 * 1024

  # Optional structured logging controls
  config.logger = Rails.logger
  config.log_context = ->(context) { { actor_id: context&.id } }
end
```

Use validation when a UI or API needs to report rejected filter nodes before it runs a query:

```ruby
diagnostics = Scry.validate_filter(model: User, filter: filter, context: current_user)
diagnostics.map(&:to_h)
# => [{ code: :permission_denied, path: [:filters, 0], message: "..." }, ...]
```

`filter_records_by` returns the relation and diagnostics together:

```ruby
result = Scry.filter_records_by(
  records: User.where(active: true), filter: filter, context: current_user
)
result.success?     # all requested nodes compiled
result.partial?     # valid siblings compiled and invalid siblings were skipped
result.failed?      # no requested node compiled, or a fail-closed error occurred
result.relation     # ActiveRecord::Relation
result.diagnostics  # immutable Diagnostic objects
```

Custom filter classes should use the Result factories so every non-success result
has a structured diagnostic:

```ruby
Result.success(relation)
Result.partial(relation, diagnostics: diagnostics)
Result.failure(relation: relation, message: '...', category: :permission_denied, code: :property_denied, path: path)
```

Successful results have no diagnostics. Partial and failed results require at least
one `Diagnostic`; the relation remains the caller's authorized scope until the
configured policy applies. Result construction is pure. Diagnostic logging happens
once at the public operation boundary and is suppressed completely by `:silent`.

Each diagnostic has a broad `category`, a specific `code`, a nested `path`, and a safe `message`. For example, a denied property has category `:permission_denied` and code `:property_denied`. Hosts can map codes to field errors without parsing messages.
`validate_filter` collects diagnostics without selecting records. They do not replace authorization:
the caller still decides whether the context may access the resulting records. Keep `log_context` limited to stable,
redacted identifiers; it is the explicit opt-in hook for adding context to structured log entries. Validation temporarily
uses `invalid_filter_policy: :skip` and preserves the configured `callback_error_policy`.

`invalid_filter_policy` controls the entire tree when compilation reports a diagnostic:

| Policy | Result |
|---|---|
| `:skip` (default) | Return a partial or failed result and apply valid nodes |
| `:raise` | Raise `Scry::FilterError` with the completed result in `error.result` |
| `:match_none` | Return a failed result with an empty relation |

Set the policy with `config.invalid_filter_policy = :raise` inside `Scry.configure`. Callback and mandatory model-scope failures always fail closed. Under `:raise`, the error carries the failed result.
Diagnostic logging is independent of result policy: `:silent` suppresses diagnostic log writes and `:warn` writes each
diagnostic once through the configured logger at the public operation boundary. Permission-denied diagnostics follow the
same setting. The supported invalid-filter policies are only `:skip`, `:raise`, and `:match_none`; the
supported diagnostic logging modes are only `:silent` and `:warn`. Logging enrichment failures omit the context and add
`logging_error: true`; logger failures do not replace the original filtering result or exception.

### Temporary configuration

Use `with_temporary_settings` to run code with modified configuration. It snapshots scalar settings and registry contents, and restores both after the block.

```ruby
Scry.configuration.with_temporary_settings do |config|
  config.invalid_filter_policy = :raise
  config.strict = true
  # ... code runs with these settings
end
# original settings restored
```

This is thread-safe and supports nesting.

In Rails, global scalar settings are locked after initialization, after registry
lookups are warmed. Change those settings during application boot. Register
predicates, aggregates, and filter classes during boot or inside an idempotent
`to_prepare` setup block so reloadable classes can refresh their registrations.
Do not mutate registries concurrently with filtering. After scalar settings are
locked, use `with_temporary_settings` for a scoped override; it is restored even
when the block raises. Standalone users may call
`Scry.configuration.lock_settings!` after boot configuration is complete.
Permission callbacks and their request contexts remain dynamic and are not
affected by scalar configuration locking.

## I18n

The gem translates predicate names, property labels, and association labels using Rails I18n.

### Predicate labels

Define translations under `scry.predicates`:

```yaml
# config/locales/scry.en.yml
en:
  scry:
    predicates:
      eq: "equals"
      not_eq: "does not equal"
      matches: "contains"
      starts_with: "starts with"
      gt: "greater than"
      between: "between"
      within: "within last"
      has_any: "has any of"
      # ...
    aggregates:
      count: "count"
      sum: "sum"
      avg: "average"
      min: "minimum"
      max: "maximum"
```

### Property labels

Property labels use Rails' `human_attribute_name`, which reads from:

```yaml
en:
  activerecord:
    attributes:
      user:
        first_name: "First name"
        date_of_birth: "Date of birth"
```

### Association labels

Association labels can be customized via:

```yaml
en:
  activerecord:
    associations:
      user:
        emails: "Email addresses"
        organisation: "Company"
```

Without a translation, the association name is humanized (e.g., `service_industries` becomes "Service industries").

### Locale parameter

Pass a locale to `filter_capabilities`:

```ruby
Scry.filter_capabilities(model: User, context: current_user, locale: :fr)
User.filter_capabilities(current_user, locale: :de)
```

## Caching

Permission calculations are cached in thread-local storage with LRU eviction (max 1000 entries per model). This prevents repeated permission resolution within a single request or job.
The cache is a snapshot for the current thread and authorization context. Keep that context stable for the lifetime of
the request or job; if the host changes principal, tenant, locale-sensitive policy inputs, or another authorization
context value on the same thread, clear the caches before filtering again. Cache entries do not provide authorization
isolation across principals by themselves.

### Automatic clearing (Rails)

The `CacheClearer` middleware is automatically inserted by the Railtie. It clears thread-local caches after each request.

### Manual clearing

For background jobs, console sessions, scripts, and other non-Rack contexts, clear caches manually at the execution
boundary:

```ruby
# Clear all thread caches
Scry.clear_thread_caches!

# Or use the middleware's class method
Scry::Middleware::CacheClearer.clear_current_thread!
```

**Sidekiq example:**

```ruby
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Scry::Middleware::CacheClearer
  end
end
```

**ActiveJob example:**

```ruby
class ApplicationJob < ActiveJob::Base
  around_perform do |_job, block|
    block.call
  ensure
    Scry.clear_thread_caches!
  end
end
```

### Invalidation

Permission caches are automatically invalidated when:
- A predicate or aggregate is registered/unregistered
- Type groups change
- Rails reloads classes in development

You can also manually invalidate:

```ruby
User.scry_permissions.clear_caches!
```

## Custom filter classes

Extend the gem with your own filter types by subclassing `Filters::Base`. A custom filter receives the configured
constructor arguments (`model:`, `filter:`, `context:`, and `depth:`) and must return an
`Scry::Result`. Return `success(relation)` after compiling a node. Use `failure(message, category:, code:)`
for an expected invalid payload or denied capability. Do not rescue unexpected programming errors: they should remain
visible to the host's error handling.

`filter`, `context`, `model`, `scope`, `depth`, and `diagnostic_path` are protected readers. `source_relation` and `source_attribute(:name)` preserve a caller's derived-table alias. Use them whenever the
filter reads a model attribute or begins a relation, including a filter invoked from a nested group. Do not start from
`Model.unscoped` or write a direct SQL query that bypasses the supplied source; doing so can discard caller constraints
and mandatory model scopes.

```ruby
class GeoFilter < Scry::Filters::Base
  def property
    @_property ||= safe_to_sym(@filter[:property])
  end

  def apply
    return failure("Scry: geo property is not allowed", category: :permission_denied, code: :property_denied) unless valid_property?
    lat = filter[:latitude]
    lng = filter[:longitude]
    radius = filter[:radius]

    # This example assumes PostgreSQL/PostGIS and an allowed geography column.
    # Arel supplies the current FROM alias; the values remain bound parameters.
    location = source_attribute(property)
    success(source_relation.where(
      "ST_DWithin(#{location.to_sql}::geography, ST_Point(?, ?)::geography, ?)",
      lng, lat, radius
    ))
  end
end

Scry.configure do |config|
  config.register_filter(:geo, GeoFilter)
end
```

Then use it in filters:

```ruby
{
  type: "group",
  predicate: "and",
  filters: [
    { type: "geo", property: "location", latitude: 40.7128, longitude: -74.0060, radius: 5000 }
  ]
}
```

Custom filters work at the root, within `and` and `or` groups, and under group negation. The public entry point always
returns the compiled relation and its diagnostics together:

```ruby
# A custom filter can be the whole request.
result = Scry.filter_records_by(records: Place.all, filter: {
  type: "geo", property: "location", latitude: -33.87, longitude: 151.21, radius: 5000
}, context: current_user)

# It can compose with standard filters. A malformed sibling makes this :partial
# under :skip; a callback or model-scope error is always :failed.
result = Scry.filter_records_by(records: Place.all, filter: {
  type: "group", predicate: "or", filters: [
    { type: "geo", property: "location", latitude: -33.87, longitude: 151.21, radius: 5000 },
    { type: "property", property: "featured", predicate: "eq", args: [true] }
  ]
}, context: current_user)

places = result.relation
issues = result.diagnostics
```

Custom filters can resolve saved definitions in host-owned storage and compile the
resolved definition through the inherited `compile_nested_filter` method. The host
owns storage, authorization, unavailable-record handling, and reference-cycle checks.
Pass one resolver through the filtering context so nested saved filters share its
reference stack:

```ruby
FilterContext = Struct.new(:actor, :saved_filter_store, keyword_init: true)

class SavedFilter < Scry::Filters::Base
  def apply
    context.saved_filter_store.with_definition(filter[:id]) do |definition|
      return failure('Saved filter is unavailable', code: :saved_filter_unavailable) unless definition.is_a?(Hash)

      compile_nested_filter(definition, path: [*diagnostic_path, :saved_filter])
    end
  rescue SavedFilterStore::RecursiveReference
    failure('Saved filter references itself', code: :saved_filter_recursive)
  end
end

class SavedFilterStore
  class RecursiveReference < StandardError; end

  def initialize(actor)
    @actor = actor
    @stack = []
  end

  def with_definition(id)
    record = SavedFilterRecord.authorized_for(@actor).find_by(id:)
    return yield(nil) unless record

    canonical_id = record.id.to_s
    raise RecursiveReference if @stack.include?(canonical_id)

    @stack << canonical_id
    begin
      yield(record.definition)
    ensure
      @stack.pop
    end
  end
end

Scry.configuration.register_filter(:saved_filter, SavedFilter)

filter_context = FilterContext.new(
  actor: current_user,
  saved_filter_store: SavedFilterStore.new(current_user)
)
result = Scry.filter_records_by(
  records: Place.all,
  filter: { type: 'saved_filter', id: saved_filter_id },
  context: filter_context
)
```

If a saved definition is unavailable, the custom filter returns a normal diagnostic.
The configured `:skip`, `:raise`, and `:match_none` policies apply to that result like
any built-in filter. `compile_nested_filter` normalizes the DSL keys and preserves
values such as JSON predicate arguments, the caller's authorized relation, source
alias, depth, and diagnostic path. Storage, authorization, and cycle detection remain
host-owned. The resolver must keep one stack through nested saved-filter references,
including references inside group filters, and must remove each pushed ID after the
lookup block finishes.

## Rails integration

When Rails is detected before `rails_scry` is required, the optional Railtie:

1. **Loads I18n locale files** from the gem's `config/locales/` directory
2. **Inserts CacheClearer middleware** into the Rack middleware stack
3. **Warms registry lookups** after initialization
4. **Invalidates permission caches** on `config.to_prepare`

The Railtie does not install global Arel extensions implicitly. Call `Scry.install_arel_extensions!` during
application boot only when an application depends on those compatibility methods.
Locale files are registered through the Rails application lifecycle, unless the application already owns the same
locale path. Requiring `rails_scry` without Rails registers the packaged locale directly.

Register filters, predicates, aggregates, and type groups during application boot. Do not change registrations while requests or jobs use them.
Concurrent registration and filtering are outside the supported contract. `warm!` precomputes lookup caches.
Read `filter_class_mappings` as an immutable snapshot and use `register_filter` to change registrations.

Register extensions that reference reloadable application classes in Rails preparation callbacks:

```ruby
Rails.application.config.to_prepare do
  Scry.configure do |config|
    config.register_filter(:geo, GeoFilter)
  end
end
```

Also re-register predicate and aggregate builders when they capture reloadable classes.
Rails preparation replaces the class references through registration. Cache invalidation alone does not reload a registered extension.
Keep preparation callbacks idempotent; repeated preparation must replace definitions rather than append duplicate application rules.

## Compatibility and limits

The CI compatibility workflow resolves the following Rails and Ruby lines and runs the core contracts on each pair:

| Rails | Ruby |
|-------|------|
| 7.1 | 3.1 |
| 7.2 | 3.2 |
| 8.0 | 3.3 |
| 8.1 | 3.3 |

All 12 version/adapter cells passed in isolated local Docker runs on 7 September 2026;
see [resolved versions and validation results](docs/compatibility-results.md). Hosted GitHub Actions was not run.
PostgreSQL runs the full regression suite. SQLite and MySQL run adapter-neutral core and shared boundary contracts;
PostgreSQL-only predicates are gated by adapter.

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

Discovery uses the model's logical attribute type, with physical array metadata retained for adapter-native predicates. Property-result aggregates serialize operands with the associated model's attribute type. Changing a filterable model's attributes, table name, or schema information invalidates dependent discovery caches. Call `reset_column_information` after changing schema, as required by ActiveRecord.

Extension registration rejects abstract filter classes, incompatible constructors, malformed metadata, and callbacks that cannot accept the documented positional arguments. Zero-operand predicate lambdas can accept just the attribute. An `arel_predicate` method must already be installed when the predicate is registered; install Arel extensions before calling `register_predicate`. Callback errors during discovery follow `callback_error_policy`. Registry entries, including temporary configuration snapshots, are immutable; change definitions through registration APIs.

Public RBS declarations cover configuration, registries, discovery, diagnostics, permissions, and filter extensions. ActiveRecord and Arel objects remain `untyped` so consumers do not need an additional Rails signature package. Signature validation checks declaration consistency; runtime behavior is covered by the regression suite.

Polymorphic `belongs_to` traversals require a static target allowlist, and composite primary and join keys are
supported when the model exposes the complete ordered key. Association scopes with `limit` or `offset` are evaluated
per owner using a windowed candidate relation. Owner-dependent Ruby scopes cannot be joined and are rejected.

A custom `FROM` must use an Arel table alias, and the incoming relation must already reference that alias correctly. Custom filters return `Scry::Result`, not a bare relation. Use `source_relation` and `source_attribute(:name)` when a filter must read the caller's derived source. Successful custom relations must retain a selectable model primary key. Grouped membership projections must group by the current source's primary key. A different table's identically named key does not qualify. Use an Arel attribute or a simple qualified identifier; opaque SQL grouping expressions are rejected.

When a custom relation uses `LIMIT` or `OFFSET`, ordering by a selected alias that would be removed by primary-key projection is rejected during compilation. The diagnostic names the alias and recommends ordering by the aggregate expression directly (for example, `order(table[:name].maximum.desc)`) or exposing the ordering field through an Arel derived source. Without pagination, ordering is discarded safely. This error follows the configured error-handling and invalid-filter policies.
Filter permissions control filtering capabilities. Mandatory model scopes define the rows the engine can examine. Hosts still choose and register their authorization policy.

## Development

The default development bundle requires Ruby 3.3 or newer because it uses Rails 8.1. The gem itself supports Ruby 3.1 with ActiveRecord 7.1. Use the compatibility Gemfiles for older supported pairs.

Native ActiveRecord CTE support is required. ActiveRecord 7.0 and earlier are no longer supported.
Custom filter relations can use `with(...)`; Boolean composition preserves their CTE definitions through a primary-key subquery.
Ordering and pagination remain on the caller relation unless requested by the filter's group selection modifiers. The compiler preserves the caller's authorization and tenant scope.

## Requirements

- Ruby >= 3.1.0
- ActiveRecord >= 7.1, < 9.0
- ActiveSupport >= 7.1, < 9.0
- Rails and Railties are optional integration dependencies

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/NicolasJJensen/rails_scry.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
