# frozen_string_literal: true

require "logger"
require "json"
require "set"
require "monitor"
require "active_support"
require "active_support/concern"
require "active_support/core_ext/hash"
require "active_support/core_ext/object/deep_dup"
require "active_record"
require "singleton"

require_relative "scry/version"

module Scry
  class FilterError < StandardError
    attr_reader :result

    def initialize(message = nil, result: nil)
      super(message)
      @result = result
    end
  end
  class InvalidOperandError < FilterError; end
  class ModelScopeError < FilterError; end
  # Internal control-flow signal for the match-none callback policy. It must
  # remain distinct from malformed-filter errors so filter nodes cannot
  # swallow it and accidentally produce a match-all relation.
  class CallbackFailure < StandardError
    attr_reader :diagnostic

    def initialize(message, diagnostic:)
      super(message)
      @diagnostic = diagnostic
    end
  end

  class ReportedError < FilterError
    attr_reader :diagnostic

    def initialize(diagnostic)
      super(diagnostic.message)
      @diagnostic = diagnostic
    end
  end

  module_function

  def configuration
    Configuration.instance
  end

  def logger
    configuration.logger || (Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)) || (@fallback_logger ||= Logger.new($stderr))
  end

  def invoke_callback(label:, model:, context:, path: [])
    yield
  rescue CallbackFailure
    raise
  rescue FilterError
    raise
  rescue StandardError => error
    message = "Scry: #{label} callback failed (#{error.class})"
    diagnostic = Diagnostic.new(category: :callback_error, code: :callback_error, path:, message:)
    if configuration.callback_error_policy == :raise
      error.instance_variable_set(:@scry_diagnostic, diagnostic)
      raise
    end

    raise CallbackFailure.new(message, diagnostic:)
  end

  def filter_records_by(records:, filter:, context: nil)
    result = compile_filter(records: records, filter: filter, context: context)
    log_diagnostics(result.diagnostics, model: result.relation.klass, context: context)
    apply_result_policy(result)
  rescue StandardError => error
    diagnostic = error.instance_variable_get(:@scry_diagnostic)
    log_diagnostics([diagnostic], model: records, context: context) if diagnostic
    raise
  end

  def compile_filter(records:, filter:, context: nil)
    raise ArgumentError, "filter must be a Hash, got #{filter.class}" unless filter.is_a?(Hash)
    if records.is_a?(Class) && records < ActiveRecord::Base
      records = records.all
    elsif !records.is_a?(ActiveRecord::Relation)
      raise ArgumentError, 'records must either be an ActiveRecord::Relation or an ActiveRecord::Base class'
    end
    klass = records.klass
    unless klass.respond_to?(:scry_permissions)
      return Result.failure(relation: records.none, message: 'Scry: model must include Filterable', code: :model_not_filterable)
    end
    begin
      allowed = klass.scry_permissions.model_allowed?(context)
    rescue CallbackFailure => error
      return failed_result(records.none, [error.diagnostic])
    rescue FilterError => e
      return Result.failure(relation: records.none, message: e.message, category: :permission_denied, code: :model_denied)
    end
    unless allowed
      return Result.failure(relation: records.none, message: 'Scry: model is not allowed for the given context', category: :permission_denied, code: :model_denied)
    end
    begin
      normalized = Input.normalize(filter)
      records = ModelScope.apply(records, context:)
      Compatibility.primary_keys(klass)
      source = records.from_clause.value
      if source && !source.is_a?(Arel::Nodes::TableAlias)
        raise FilterError, 'Scry: custom FROM must use an Arel table alias'
      end
      Compatibility.validate_derived_source!(records)
      filter_type = normalized[:type]
      filter_class = if filter_type.nil?
        Filters::Group
      else
        configuration.filter_class_mappings[filter_type]
      end
      unless filter_class
        return Result.failure(relation: records, message: "Scry: unknown filter type #{Input.identifier_label(filter_type)}", code: :unknown_filter_type)
      end
      result = filter_class.new(model: records, filter: normalized, context: context, depth: 0).apply
      return result if filter_class == Filters::Group

      unless result.is_a?(Result) && result.relation.is_a?(ActiveRecord::Relation) && result.relation.klass == klass
        raise FilterError, 'Scry: filter classes must return an Scry::Result for the current model'
      end

      Result.new(status: result.status,
        relation: records.where(Compatibility.condition(result.relation, outer_relation: records)),
        diagnostics: result.diagnostics)
    rescue CallbackFailure => error
      failed_result(records.none, [error.diagnostic])
    rescue ModelScopeError => e
      Result.failure(relation: records.none, message: e.message, category: :scope_error, code: :scope_error)
    rescue FilterError => e
      Result.failure(relation: records, message: e.message)
    end
  end

  def validate_filter(model:, filter:, context: nil)
    configuration.with_temporary_settings do |settings|
      settings.invalid_filter_policy = :skip
      filter_records_by(records: model, filter: filter, context: context).diagnostics
    end
  end

  def empty_information
    Immutable.copy({
      properties: [], associations: [], predicates: {}, property_predicates: {}, order: Set.new,
      association_targets: {}, aggregates: {}, aggregate_metadata: {}, aggregate_predicates: {}
    })
  end

  def filter_capabilities(model:, context: nil, locale: I18n.locale)
    unless model.is_a?(Class) && model < ActiveRecord::Base
      diagnostic = Diagnostic.new(category: :invalid_filter, code: :invalid_filter, path: [], message: 'Scry: filter_capabilities failed')
      log_diagnostics([diagnostic], model: model, context: context)
      return Immutable.copy(empty_information.merge(error: true))
    end
    unless model.respond_to?(:scry_permissions)
      diagnostic = Diagnostic.new(category: :invalid_filter, code: :invalid_filter, path: [], message: 'Scry: model must include Filterable')
      log_diagnostics([diagnostic], model: model, context: context)
      return Immutable.copy(empty_information.merge(error: true))
    end
    model.scry_permissions.to_h(context, locale: locale)
  rescue CallbackFailure => error
    log_diagnostics([error.diagnostic], model: model, context: context)
    Immutable.copy(empty_information.merge(error: true))
  rescue FilterError
    raise
  rescue NameError
    raise
  rescue StandardError => error
    if error.instance_variable_defined?(:@scry_diagnostic)
      log_diagnostics([error.instance_variable_get(:@scry_diagnostic)], model: model, context: context)
      raise
    end

    diagnostic = Diagnostic.new(category: :invalid_filter, code: :invalid_filter, path: [], message: 'Scry: filter_capabilities failed')
    log_diagnostics([diagnostic], model: model, context: context)
    Immutable.copy(empty_information.merge(error: true))
  end

  def clear_thread_caches!
    Thread.current[:scry_caches]&.clear
    Thread.current[:scry_cache_versions]&.clear
  end

  def install_arel_extensions!
    extensions = [Predications::Global, Predications::Association, Predications::Temporal]
    extensions.each do |extension|
      next if Arel::Predications.ancestors.include?(extension)
      methods = extension.instance_methods(false) | extension.private_instance_methods(false)
      conflicts = methods.select do |name|
        Arel::Predications.method_defined?(name) || Arel::Predications.private_method_defined?(name)
      end
      raise FilterError, "Scry: Arel extension method conflict: #{conflicts.join(', ')}" if conflicts.any?
    end
    extensions.each { |extension| Arel::Predications.include(extension) }
    true
  end

  def configure
    yield configuration
  end

  def log_diagnostic(event, context)
    begin
      event[:context] = configuration.log_context.call(context) if configuration.log_context
      payload = JSON.generate(event)
    rescue StandardError
      event.delete(:context)
      event[:logging_error] = true
      payload = JSON.generate(event)
    end

    begin
      logger.warn(payload) if configuration.diagnostic_logging == :warn
    rescue StandardError
      # A host logging failure must not replace the filter's diagnostic or error policy.
      nil
    end
  end

  def log_diagnostics(diagnostics, model:, context:)
    return unless configuration.diagnostic_logging == :warn

    model = model.klass if model.respond_to?(:klass)
    model_name = model.respond_to?(:name) ? model.name : model&.class&.name
    diagnostics.each do |diagnostic|
      next unless diagnostic

      log_diagnostic(
        { source: 'Scry', category: diagnostic.category, code: diagnostic.code,
          model: model_name, path: diagnostic.path, message: diagnostic.message },
        context
      )
    end
  end

  def failed_result(relation, diagnostics)
    Result.new(status: :failed, relation:, diagnostics:)
  end

  def apply_result_policy(result)
    fail_closed = result.diagnostics.any? { |diagnostic| %i[callback_error scope_error].include?(diagnostic.category) }
    if fail_closed
      result = Result.new(status: :failed, relation: result.relation.none, diagnostics: result.diagnostics)
      raise FilterError.new(result.diagnostics.first.message, result:) if configuration.invalid_filter_policy == :raise

      return result
    end

    return result if result.success?

    case configuration.invalid_filter_policy
    when :raise
      raise FilterError.new(result.diagnostics.first.message, result:)
    when :match_none
      Result.new(status: :failed, relation: result.relation.none, diagnostics: result.diagnostics)
    else
      result
    end
  end

  private_class_method :compile_filter, :log_diagnostic, :log_diagnostics, :failed_result, :apply_result_policy
end

require_relative "scry/immutable"
require_relative "scry/diagnostic"
require_relative "scry/result"
require_relative "scry/input"
require_relative "scry/expression"
require_relative "scry/order_expression_translator"
require_relative "scry/compatibility"
require_relative "scry/model_scope"
require_relative "scry/association_query"
require_relative "scry/type_registry"
require_relative "scry/base_registry"
require_relative "scry/predicate_registry"
require_relative "scry/aggregate_registry"

require_relative "scry/configuration"

require_relative "scry/filter_permissions_chain"
require_relative "scry/permission_resolver"
require_relative "scry/hash_permission_resolver"
require_relative "scry/filter_permissions"
require_relative "scry/filterable"

require_relative "scry/filters/base"
require_relative "scry/filters/group"
require_relative "scry/filters/property"
require_relative "scry/filters/association"
require_relative "scry/filters/aggregate"
require_relative "scry/filters/computed"
require_relative "scry/predications/global"
require_relative "scry/predications/association"
require_relative "scry/predications/temporal"

require_relative "scry/middleware/cache_clearer"

require_relative "scry/railtie" if defined?(Rails::Railtie)

unless defined?(Rails::Railtie)
  I18n.load_path |= Dir[File.expand_path('../config/locales/*.{rb,yml}', __dir__)]
end
