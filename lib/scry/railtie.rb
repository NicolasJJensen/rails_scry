# frozen_string_literal: true

module Scry
  # Integrates locale loading, cache lifecycle, and middleware with Rails applications.
  class Railtie < Rails::Railtie
    initializer "scry.i18n" do |app|
      locale_path = File.expand_path("../../config/locales", __dir__)
      application_locales = app.paths["config/locales"].expanded.map { |path| File.expand_path(path) }
      package_locales = Dir[File.join(locale_path, "*.{rb,yml}")]
      app.config.i18n.load_path.concat(package_locales.reject { |path| application_locales.include?(path) })
    end

    initializer "scry.middleware" do |app|
      app.middleware.use Scry::Middleware::CacheClearer
    end

    # Warm registry lookups after application boot. Applications should make
    # extension registrations during boot or in a to_prepare callback.
    config.after_initialize do
      Scry.configuration.predicate_registry.warm!
      Scry.configuration.aggregate_registry.warm!
      Scry.configuration.lock_settings!
    end

    config.to_prepare do
      Scry.configuration.invalidate_filter_caches!
      Scry.clear_thread_caches!
    end
  end
end
