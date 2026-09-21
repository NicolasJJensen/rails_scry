# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.active_support.deprecation = :stderr
  config.active_support.disallowed_deprecations_silence = []
  config.consider_all_requests_local = true
end
