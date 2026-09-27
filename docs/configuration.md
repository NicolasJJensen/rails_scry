# Configuration and result handling

Settings, result contracts, diagnostics, and lifecycle rules. See the [README](../README.md) for an introduction.

## Contents

- [Configuration](#configuration)
- [Field-level errors](#field-level-errors)

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
# => [{ code: :property_denied, path: [:filters, 0, :property], message: "..." }, ...]
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

## Field-level errors

`Diagnostic#path` follows keys and array indexes in the submitted filter. It
starts at the filter object, not at the surrounding request's `filter` key.

| Path | Origin |
|---|---|
| `[:property]` | The root filter's property selector |
| `[:filters, 1, :predicate]` | The second child filter's predicate selector |
| `[:filters, 1, :args]` | The second child's argument list or argument count |
| `[:filters, 1, :args, 0]` | Its first argument |
| `[:scoping, :filters, 0, :property]` | A property in an association or aggregate's nested scope |
| `[:expression, :operands, 1, :literal]` | A literal in a computed expression |
| `[:order, 0, :direction]` | The first ordering rule's direction |

Paths use the actual payload keys: built-in value inputs live in `args`, so their
paths use `:args` and an index rather than `:value`. Symbol keys become strings
when diagnostics are encoded as JSON. The Ruby path array is immutable.

Malformed filter nodes retain the path to that node. Whole-request limits and
failures that cannot be attributed to an input control, such as root model
permissions or mandatory model scopes, can have an empty path. Keep a form-level
error summary for those failures. Errors inside custom property expansions can
include the generated filter tree's path; applications exposing those properties
as a single control should display those errors beside that control.

For Rails HTML or Turbo Frame responses, keep the submitted filter hash and group
the diagnostics before rendering the form again:

```ruby
@filter = filter
@errors_by_path = result.diagnostics.group_by(&:path)
```

For a root property filter, mark its first argument input and associate it with
both argument-list errors and errors on that particular value:

```erb
<% errors = @errors_by_path.fetch([:args, 0], []) +
            @errors_by_path.fetch([:args], []) %>
<% args = @filter[:args] || @filter["args"] %>
<% value = args.is_a?(Array) ? args.first : args %>

<%= label_tag "filter_value", "Value" %>
<%= text_field_tag "filter[args][]", value,
                   id: "filter_value",
                   class: ("is-invalid" if errors.any?),
                   aria: { invalid: errors.any?,
                           describedby: ("filter_value_errors" if errors.any?) } %>
<% if errors.any? %>
  <ul id="filter_value_errors">
    <% errors.each do |error| %>
      <li><%= error.message %></li>
    <% end %>
  </ul>
<% end %>
```

The CSS class is application-defined. Apply the same pattern to `[:property]` and
`[:predicate]` for their selectors. For nested filters, prepend the complete node
path, such as `[:filters, 1]`. Keep a summary for diagnostics without a matching
control, including errors on the whole filter.

The [Rails response guide](rails-responses.md) provides a complete form and reusable
helper for these bindings. Its form submits real argument arrays with `args[]`.
A dynamic group builder should serialize `filters` as an array too: Rails numeric
parameter names such as `filter[filters][0]` produce a hash, not Scry's `filters`
array. Normalize that form structure in the application or send the filter as JSON.

Render errors and inputs inside the same Turbo Frame to update their messages and
invalid state together, preserving submitted values. Error paths do not change the
selected invalid-filter policy.

Custom filter classes can attach a failure to their own input fields:

```ruby
failure('Scry: invalid value', code: :invalid_value, path: field_path(:value))
```

`field_path` appends the field to the current filter's nested path. Existing custom
filters that omit `path:` continue to report errors at the filter node. Consumers
that previously matched complete node-only paths should update their field mapping
or match the node's path prefix.
