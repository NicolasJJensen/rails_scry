# Scry

Scry turns structured filter definitions into ActiveRecord relations. Use it when an API or search UI needs to let users combine conditions across fields and associations. It also exposes permission-aware metadata for building filter controls.

```ruby
result = Scry.filter_records_by(
  records: User.where(organisation: current_organisation),
  filter: { type: "property", property: "first_name", predicate: "eq", args: ["Alice"] },
  context: current_user
)
users = result.relation
```

Scry supports property comparisons, AND/OR groups, association membership, aggregates, and computed expressions. You can restrict available filters by user, translate their labels, and add your own predicates and filter types.

## Contents

- [Installation](#installation)
- [Basic usage](#basic-usage)
  - [JSON, HTML, and Turbo responses](#json-html-and-turbo-responses)
- [Permissions and context](#permissions-and-context)
- [Handling invalid filters](#handling-invalid-filters)
- [Building filters](#building-filters)
- [Building a filter UI](#building-a-filter-ui)
- [Configuration](#configuration)
- [Further documentation](#further-documentation)
- [Contributing](#contributing)
- [License](#license)

## Installation

Requires Ruby **3.1+**, ActiveRecord **7.1–8.x**, and ActiveSupport **7.1–8.x**. See [compatibility](docs/compatibility.md) for supported Ruby/Rails combinations and database-specific limits.

Add to your Gemfile and run `bundle install`:

```ruby
gem "rails_scry"
```

Include `Scry::Filterable` in your application's base model:

```ruby
class ApplicationRecord < ActiveRecord::Base
  include Scry::Filterable
  primary_abstract_class
end
```

All subclasses can now use Scry. You can instead include the concern only in the models you want to filter.

Rails loads the integration automatically, including translated labels and request cache cleanup. Rails and Railties are optional; see [standalone ActiveRecord setup](docs/integration.md) for use outside Rails.

## Basic usage

Pass an ActiveRecord relation and a filter hash to `Scry.filter_records_by`:

```ruby
filter = {
  type: "property",
  property: "first_name",
  predicate: "eq",
  args: ["Alice"]
}

result = Scry.filter_records_by(
  records: User.where(organisation: current_organisation),
  filter: filter,
  context: current_user
)

result.relation     # ActiveRecord::Relation for matching users
result.success?     # Whether every requested filter compiled
result.diagnostics # Details of rejected filters, if any
```

Start with the relation your application authorizes the caller to access. Scry preserves that scope; `context` supplies application information to permission callbacks and does not authorize records by itself.

Filters are Ruby hashes or parsed JSON objects with string keys. `args` contains positional predicate arguments: `args: [18, 65]` passes two bounds; `args: [[1, 2, 3]]` passes one collection. Predicates such as `eq_true` take no arguments.

By default, invalid filter nodes are skipped and valid nodes still apply. Inspect the result before deciding how to respond; [invalid-filter handling](#handling-invalid-filters) explains the alternatives.

### JSON, HTML, and Turbo responses

Scry returns the same relation and diagnostics for every response format. After
filtering, a Rails action can assign the result to its views and choose how to
respond:

```ruby
@filter = filter
@result = result
@users = result.success? ? result.relation : result.relation.none
@errors_by_path = result.diagnostics.group_by(&:path)
status = result.success? ? :ok : :unprocessable_entity

respond_to do |format|
  format.html { render :index, status: status }
  format.turbo_stream { render :index, status: status }
  format.json do
    if result.success?
      render json: @users.as_json(only: [:id, :first_name])
    else
      render json: { errors: result.diagnostics.map(&:to_h) }, status: status
    end
  end
end
```

- **HTML:** Render the filter form, submitted values, errors, and results in `index.html.erb`.
- **Turbo Frames:** Return HTML containing the same frame ID on success and failure. Put the form, errors, and results inside that frame so they update together. A frame request does not need a Turbo Stream response.
- **Turbo Streams:** Render `index.turbo_stream.erb` to replace the search area. A GET form must opt into stream responses with `data-turbo-stream`.
- **JSON:** Return selected record fields on success, or structured diagnostics on failure.

This example rejects partial and failed filters with a 422 response. Show an error
summary and mark affected controls invalid; only show “No users found” after a
successful query with zero matches. Keep submitted inputs available for correction.

The [Rails response guide](docs/rails-responses.md) includes the complete controller,
HTML form, field-error helper, matching Turbo Frame, and Turbo Stream template. It
also handles the initial page load, malformed parameters, and `:raise` policy.
Turbo examples assume the host application has Turbo installed.

## Permissions and context

By default, Scry exposes eligible model properties for filtering. **ActiveRecord-declared encrypted attributes and `belongs_to` foreign-key columns are excluded.** Associations are available only when their target models support Scry and allow filtering; polymorphic associations require registered targets. Scry does not infer that other columns are sensitive from their names. Use permissions to further restrict the available properties, associations, and predicates:

```ruby
class User < ApplicationRecord
  add_filter_permission(:properties, list_type: :whitelist) do |_context|
    [:first_name, :last_name, :active, :age, :created_at]
  end

  add_filter_permission(:associations, list_type: :whitelist) do |_context|
    [:emails]
  end
end
```

Each permission callback receives the `context` passed to filtering or discovery. For example, it can expose extra fields to administrators. Associated models need their own appropriate permissions.

Filtering permissions determine **which conditions are available**. Row authorization determines **which records those conditions can examine**. Pass an authorized relation as above; use mandatory model scopes when a policy must also apply whenever Scry traverses a model:

```ruby
class User < ApplicationRecord
  add_filter_scope do |current_user|
    where(organisation_id: current_user.organisation_id)
  end
end
```

This example assumes users belong to one organisation. Use your application's policy in the callback. Multiple model scopes intersect with the caller relation, and Scry also applies registered scopes to associated and through models. Register the appropriate scope on each model that needs it.

For an explicit-grants approach, enable `config.strict = true`. Properties, associations, predicates, and aggregates then start empty; grant them with `includelist`. A `whitelist` narrows an existing set and cannot grant access in strict mode.

See the [permissions guide](docs/permissions.md) for context-dependent rules, strict-mode setup, model gates, and precedence.

## Handling invalid filters

`Scry.filter_records_by` returns a `Scry::Result`:

| Method | Meaning |
|---|---|
| `success?` | All requested filter nodes compiled |
| `partial?` | Valid nodes compiled while invalid nodes were skipped |
| `failed?` | No requested node compiled, or a failure required an empty result |
| `relation` | The resulting ActiveRecord relation |
| `diagnostics` | Structured errors with a category, code, path, and message |

Choose the invalid-filter policy during application boot:

| Policy | Behavior |
|---|---|
| `:skip` (default) | Apply valid nodes and report skipped nodes; if none apply, the authorized scope may remain unchanged |
| `:raise` | Raise `Scry::FilterError`; inspect `error.result` for diagnostics |
| `:match_none` | Return a failed result with an empty relation |

Unexpected permission and extension callback errors raise by default, controlled separately by `callback_error_policy`. Mandatory model-scope failures never return an unrestricted relation. See [configuration and error handling](docs/configuration.md) for the full policies.

A UI can validate a filter without selecting matching records:

```ruby
diagnostics = Scry.validate_filter(model: User, filter: filter, context: current_user)
errors = diagnostics.map(&:to_h)
```

Each diagnostic's `path` identifies its location in the filter payload. For
example, `[:filters, 1, :property]` points to the second filter's property selector,
while `[:filters, 1, :args, 0]` points to its first value input. Use these paths to
display errors beside the affected controls and mark them invalid. See
[field-level errors](docs/configuration.md#field-level-errors) for a Rails example.

## Building filters

The examples below use users with names, an `active` flag, a numeric `age`, and an `emails` association. Pass any example as the `filter:` argument.

### Property comparisons

```ruby
{ type: "property", property: "first_name", predicate: "matches", args: ["ali"] }
{ type: "property", property: "age", predicate: "between", args: [18, 65] }
{ type: "property", property: "active", predicate: "eq_true" }
{ type: "property", property: "created_at", predicate: "within_previous", args: ["P7D"] }
```

These match a name containing `ali`, an age range, an active user, and a creation time within the past seven days, respectively. See the [predicate reference](docs/predicates.md) for equality, text, numeric, temporal, and adapter-specific comparisons.

### Combining conditions

Use a group with `and` or `or`. Groups can contain other groups:

```ruby
{
  type: "group",
  predicate: "and",
  filters: [
    { type: "property", property: "active", predicate: "eq_true" },
    { type: "property", property: "age", predicate: "gteq", args: [18] }
  ]
}
```

### Association membership

Find users associated with at least one of the specified email records:

```ruby
{ type: "association", association: "emails", predicate: "has_any", args: [[1, 2, 3]] }
```

Other association predicates express all, none, or exact membership. Use `scoping` to apply conditions to the associated records; see the [filter reference](docs/filters.md).

### Aggregates

Find users with at least three emails:

```ruby
{ type: "aggregate", association: "emails", aggregate: "count", predicate: "gteq", args: [3] }
```

Built-in aggregates include `count`, `sum`, `avg`, `min`, and `max`. Aggregates other than `count` require a `property` on the associated model. A count of zero includes users without matching emails.

### Computed expressions

Compare arithmetic expressions over permitted fields. For example, express a user's age in months:

```ruby
{
  type: "computed",
  expression: {
    operator: "multiply",
    operands: [{ property: "age" }, { literal: 12 }]
  },
  predicate: "gteq",
  args: [216]
}
```

Expressions support `add`, `subtract`, `multiply`, and `divide`, with nested expressions and finite numeric literals. Referenced fields and their comparison predicates must be permitted.

### Negation

Add `negate: true` to invert a filter:

```ruby
{ type: "property", property: "first_name", predicate: "eq", args: ["Alice"], negate: true }
```

See the [filter reference](docs/filters.md) for payload schemas, empty-set behavior, association scoping, and advanced query constraints.

## Building a filter UI

Use the same model and context to discover which controls a user can select:

```ruby
info = Scry.filter_capabilities(model: User, context: current_user, locale: I18n.locale)

info[:properties]                  # Available fields with labels and types
info[:property_predicates]         # Permitted comparisons for each field
info[:associations]                # Available associations
```

Use properties for a field selector and `property_predicates` for its comparison selector. Discovery respects permissions and database adapter support; metadata is an immutable snapshot.

The [discovery reference](docs/discovery.md) describes the complete schema, predicate arguments, aggregate metadata, and error reporting. Labels can be [translated with I18n](docs/integration.md#i18n).

## Configuration

Set application-wide behavior in an initializer:

```ruby
# config/initializers/scry.rb
Scry.configure do |config|
  config.invalid_filter_policy = :match_none
  config.callback_error_policy = :raise
  config.diagnostic_logging = :warn
end
```

This example returns no records for invalid filters, raises unexpected callback errors, and logs diagnostics. The default invalid-filter policy is `:skip`.

Configure settings and extensions during boot. Rails locks scalar settings after initialization; extensions that refer to reloadable application classes need an idempotent `to_prepare` registration. See [configuration](docs/configuration.md) and [Rails integration](docs/integration.md#rails-integration) for limits, logging, temporary overrides, and reload behavior.

## Further documentation

| Guide | Topics |
|---|---|
| [Rails responses](docs/rails-responses.md) | JSON, HTML, Turbo Frames and Streams, preserved form values, and field errors |
| [Filters](docs/filters.md) | Complete payload formats, computed expressions, association and aggregate behavior |
| [Predicates](docs/predicates.md) | Built-in comparisons, argument shapes, adapter-specific support |
| [Permissions](docs/permissions.md) | Context, mandatory scopes, strict mode, list semantics and precedence |
| [Discovery](docs/discovery.md) | Metadata for fields, predicates, associations, and aggregates |
| [Configuration](docs/configuration.md) | Result contracts, diagnostics, error policies, limits, and logging |
| [Extensions](docs/extensions.md) | Custom predicates, aggregates, transforms, types, and filter classes |
| [Integration](docs/integration.md) | Standalone ActiveRecord, Rails lifecycle, I18n, and cache management |
| [Compatibility](docs/compatibility.md) | Supported versions, adapters, and query limitations |

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/NicolasJJensen/rails_scry). See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, tests, lint, and compatibility checks.

## License

Scry is available under the [MIT License](LICENSE.txt).
