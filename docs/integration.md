# ActiveRecord and Rails integration

Setup, Rails lifecycle behavior, labels, and cache management. See the [README](../README.md) for an introduction and [Rails responses](rails-responses.md) for JSON, HTML, Turbo, and form-error examples.

## Contents

- [Standalone ActiveRecord](#standalone-activerecord)
- [Rails integration](#rails-integration)
- [I18n](#i18n)
- [Caching](#caching)

## Standalone ActiveRecord

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
