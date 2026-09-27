# Permissions and authorization

Scry filters the relation supplied by the host application. Use a mandatory
model scope to define the rows the engine may inspect, then restrict exposed
properties, associations, predicates, and aggregates. The request `context`
flows through every permission and scope callback.

## Contents

- [Recommended setup](#recommended-setup)
- [Permission list types](#permission-list-types)
- [Property permissions](#property-permissions)
- [Association permissions](#association-permissions)
- [Predicate permissions](#predicate-permissions)
- [Aggregate permissions](#aggregate-permissions)
- [Model-level permissions](#model-level-permissions)
- [Mandatory model scopes](#mandatory-model-scopes)
- [Context-based permissions](#context-based-permissions)
- [Strict mode](#strict-mode)

## Recommended setup

```ruby
class User < ApplicationRecord
  add_filter_scope :readable_by_context

  add_filter_permission(:properties, list_type: :whitelist) do |context|
    fields = [:first_name, :last_name, :active]
    fields += [:email, :phone] if context&.admin?
    fields
  end

  def self.readable_by_context(context)
    where(organisation_id: context.organisation_id)
  end
end
```

Pass the same context when filtering and discovering capabilities:

```ruby
result = Scry.filter_records_by(records: User.all, filter:, context: current_user)
options = Scry.filter_capabilities(model: User, context: current_user)
```

A scope must return a relation for the same model. Scopes inherit, and multiple
scopes intersect with the caller relation by the complete primary key. Scry
applies target and through-model scopes before association limits, membership,
aggregates, and negation. A scope that raises, returns `nil`, or returns a
relation for another model fails closed.


## Permission list types

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
User.add_filter_permission(:order, list_type: :whitelist) { [:created_at, :first_name] }
```

Polymorphic associations require an explicit application allowlist. Register target models during boot;
discovery exposes only targets allowed for the current context:

```ruby
Comment.add_filter_targets(:commentable, post: Post, photo: Photo)
```

**Default behavior:** Eligible model properties are filterable with applicable predicates. ActiveRecord-declared encrypted attributes and foreign-key columns used by `belongs_to` associations are excluded from the property universe, including composite foreign keys. An `includelist` cannot re-enable these excluded properties. Column names alone do not identify sensitive fields: an ordinary column named `password_digest` or `reset_password_token` still needs an explicit restriction.

Associations are available only when the target model includes `Scry::Filterable` and its model permission allows access. Polymorphic associations also need a registered target that meets those conditions. Use property, association, and predicate permissions to narrow these defaults.

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

## Property permissions

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

## Association permissions

Control which associations users can filter through.

```ruby
class User < ApplicationRecord
  add_filter_permission(:associations, list_type: :whitelist) do |context|
    [:emails, :organisation]
  end
end
```

The gem automatically excludes associations whose target model returns `false` from `model_allowed?`.

## Predicate permissions

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

## Aggregate permissions

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

## Model-level permissions

Allow or deny filtering on an entire model.

```ruby
class InternalAuditLog < ApplicationRecord
  add_model_permission do |context|
    context.respond_to?(:admin?) && context.admin?
  end
end
```

The block should return `true` (allow), `false` (deny), or `nil` (default allow). A denied model produces a failed result with an empty relation and a redacted diagnostic. Use `add_model_permission` for this boolean gate; generic `add_filter_permission(:model, list_type: ...)` is rejected because list policies do not apply to model-level decisions.

## Mandatory model scopes

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

## Context-based permissions

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

## Strict mode

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

[Back to the README](../README.md#permissions-and-context)
