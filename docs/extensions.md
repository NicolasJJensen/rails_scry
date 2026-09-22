# Extension reference

Detailed APIs for extending the filtering language. See the [README](../README.md) for an introduction.

## Contents

- [Custom predicates](#custom-predicates)
- [Custom aggregates](#custom-aggregates)
- [Transforms](#transforms)
- [Type system](#type-system)
- [Custom filter classes](#custom-filter-classes)

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
  config.register_predicate(:different_from,
    arel_predicate: :not_eq,
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
