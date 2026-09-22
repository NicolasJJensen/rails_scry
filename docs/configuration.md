# Configuration and result handling

Settings, result contracts, diagnostics, and lifecycle rules. See the [README](../README.md) for an introduction.

## Contents

- [Configuration](#configuration)

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
