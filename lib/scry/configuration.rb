# frozen_string_literal: true

module Scry
  class Configuration
    include Singleton

    INVALID_FILTER_POLICIES = %i[skip raise match_none].freeze
    CALLBACK_ERROR_POLICIES = %i[raise match_none].freeze
    DIAGNOSTIC_LOGGING_MODES = %i[silent warn].freeze
    PREDICATE_FILTER_KINDS = %i[property association computed aggregate].freeze
    ASSOCIATION_UNSUPPORTED_AREL_PREDICATES = %i[eq not_eq eq_any eq_all not_eq_any not_eq_all].freeze

    attr_reader :predicate_registry, :aggregate_registry, :invalid_filter_policy
    attr_reader :callback_error_policy, :diagnostic_logging
    attr_reader :max_filter_depth, :strict, :max_filter_nodes, :max_filter_bytes
    attr_reader :logger, :log_context

    class << self
      alias_method :global_instance, :instance

      def instance
        # Scoped settings must not change configuration used by concurrent filtering.
        Thread.current[:scry_configuration] || global_instance
      end
    end

    def cache_key
      [object_id, @revision, predicate_registry.cache_key, aggregate_registry.cache_key]
    end

    def strict=(value)
      ensure_settings_mutable!
      @strict = !!value
      invalidate_filter_caches!
    end

    def logger=(value)
      ensure_settings_mutable!
      @logger = value
    end

    def log_context=(value)
      ensure_settings_mutable!
      @log_context = value
    end

    def max_filter_nodes=(value)
      ensure_settings_mutable!
      @max_filter_nodes = positive_limit(value, :max_filter_nodes)
    end

    def max_filter_bytes=(value)
      ensure_settings_mutable!
      @max_filter_bytes = positive_limit(value, :max_filter_bytes)
    end

    def invalid_filter_policy=(value)
      ensure_settings_mutable!
      value = value.to_sym if value.is_a?(String)
      unless INVALID_FILTER_POLICIES.include?(value)
        raise ArgumentError,
          "invalid_filter_policy must be one of #{INVALID_FILTER_POLICIES.inspect}, got #{value.inspect}"
      end
      @invalid_filter_policy = value
    end

    def callback_error_policy=(value)
      ensure_settings_mutable!
      value = value.to_sym if value.is_a?(String)
      unless CALLBACK_ERROR_POLICIES.include?(value)
        raise ArgumentError,
          "callback_error_policy must be one of #{CALLBACK_ERROR_POLICIES.inspect}, got #{value.inspect}"
      end
      @callback_error_policy = value
    end

    def diagnostic_logging=(value)
      ensure_settings_mutable!
      value = value.to_sym if value.is_a?(String)
      unless DIAGNOSTIC_LOGGING_MODES.include?(value)
        raise ArgumentError,
          "diagnostic_logging must be one of #{DIAGNOSTIC_LOGGING_MODES.inspect}, got #{value.inspect}"
      end
      @diagnostic_logging = value
    end

    def max_filter_depth=(value)
      ensure_settings_mutable!
      value = Integer(value)
      raise ArgumentError, "max_filter_depth must be >= 1, got #{value}" unless value >= 1
      @max_filter_depth = value
    end

    def settings_locked?
      !!@settings_locked
    end

    def lock_settings!
      @settings_locked = true
      self
    end

    delegate :types, to: :predicate_registry

    def initialize
      @revision = 0
      @settings_locked = false
      @predicate_registry = PredicateRegistry.new
      @aggregate_registry = AggregateRegistry.new(type_registry: @predicate_registry.type_registry)
      @filter_class_mappings = {
        group: Filters::Group,
        association: Filters::Association,
        property: Filters::Property,
        aggregate: Filters::Aggregate,
        computed: Filters::Computed
      }.with_indifferent_access
      self.invalid_filter_policy = :skip
      self.callback_error_policy = :raise
      self.diagnostic_logging = :silent
      @strict = false
      self.max_filter_depth = 15
      self.max_filter_nodes = 1000
      self.max_filter_bytes = 1_048_576
      setup_defaults
    end

    # A registered class's #apply must return Result so group composition can preserve
    # diagnostics and the configured error policy.
    def register_filter(type, klass)
      validate_name!(type)
      unless klass.is_a?(Class) && klass < Filters::Base
        raise ArgumentError, 'filter class must inherit from Scry::Filters::Base'
      end
      if klass.instance_method(:apply).owner == Filters::Base
        raise ArgumentError, 'filter class must implement apply'
      end
      parameters = klass.instance_method(:initialize).parameters
      keywords = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
      required = parameters.filter_map { |kind, name| name if kind == :keyreq }
      expected = %i[model filter context depth]
      unless parameters.none? { |kind, _| kind == :req } && (required - expected).empty? &&
          (parameters.any? { |kind, _| kind == :keyrest } || (expected - keywords).empty?)
        raise ArgumentError, 'filter constructor must accept model, filter, context, and depth keywords'
      end
      @filter_class_mappings[type] = klass
      invalidate_filter_caches!
    end

    def filter_class_mappings
      @filter_class_mappings.dup.freeze
    end

    def register_predicate(name, types: [:all], applies_to: [:property], compounds: false, arel_predicate: nil, formatter: nil, validator: nil, adapters: nil, prepare_arguments: nil, &block)
      validate_definition!(name, types, adapters)
      applies_to = validate_applies_to!(applies_to)
      validate_callback!(validator, [1], 'validator') if validator
      validate_callback!(formatter, [1], 'formatter') if formatter
      validate_callback!(prepare_arguments, [1], 'prepare_arguments') if prepare_arguments
      name = name.to_sym
      any_name = "#{name}_any".to_sym
      all_name = "#{name}_all".to_sym

      if arel_predicate && block
        raise ArgumentError, 'predicate registration cannot provide both arel_predicate and a block'
      end

      arel_predicate = arel_predicate&.to_sym
      arel_predicate ||= name unless block
      validate_association_predicate!(arel_predicate, applies_to)
      # A callback is explicit host behavior; do not silently replace it with an
      # Arel method that happens to share its registry name.
      # Derive validation and discovery from the callable so they cannot drift
      # from its Ruby signature.
      signature = if block
        predicate_signature(block, receiver: 1)
      else
        predicate_signature(arel_predicate_method(arel_predicate, applies_to:), receiver: 0)
      end

      entries = [{
        name:,
        arel_predicate:,
        custom_predicate: block,
        **signature,
        formatter:,
        validator:,
        prepare_arguments:,
        types:,
        applies_to:,
        adapters:,
      }]

      if compounds
        entries.concat(compound_entries(name: arel_predicate, custom_predicate: block, formatter:, validator:, types:, applies_to:,
                                        any_name:, all_name:, adapters:, prepare_arguments:))
      end

      @predicate_registry.unregister(any_name, all_name) if @predicate_registry.by_name(name)
      entries.each { |entry| @predicate_registry.register(entry) }

      invalidate_filter_caches!
    end

    def unregister_predicate(*names)
      @predicate_registry.unregister(*names)
      invalidate_filter_caches!
    end

    def unregister_predicate_from_type(type, *names)
      @predicate_registry.unregister_from_type(type, *names)
      invalidate_filter_caches!
    end

    def register_aggregate(name, types: [:all], result_type: :numerical, distinct: true, empty_value: nil, property: true, adapters: nil, composite_distinct: false, &builder)
      validate_definition!(name, types, adapters)
      validate_name!(result_type)
      validate_callback!(builder, [2], 'aggregate builder')
      unless [true, false].include?(distinct) && [true, false].include?(property)
        raise ArgumentError, 'aggregate distinct and property must be Boolean values'
      end
      @aggregate_registry.register({
        name: name.to_sym, types: types, result_type: result_type.to_sym,
        distinct: distinct, empty_value: empty_value, property: property,
        adapters: adapters, composite_distinct: composite_distinct, builder: builder
      })
      invalidate_filter_caches!
    end

    def unregister_aggregate(*names)
      @aggregate_registry.unregister(*names)
      invalidate_filter_caches!
    end

    def unregister_aggregate_from_type(type, *names)
      @aggregate_registry.unregister_from_type(type, *names)
      invalidate_filter_caches!
    end

    def with_temporary_settings
      previous = Thread.current[:scry_configuration]
      temporary = self.class.send(:allocate)
      temporary.send(:load_snapshot, snapshot)
      temporary.instance_variable_set(:@settings_locked, false)
      Thread.current[:scry_configuration] = temporary
      yield temporary
    ensure
      Thread.current[:scry_configuration] = previous
      Scry.clear_thread_caches!
    end

    def invalidate_filter_caches!
      @revision = (@revision || 0) + 1
    end

    def register_types(name, *types)
      @predicate_registry.register_types(name, *types)
      invalidate_filter_caches!
    end

    def unregister_types(*names)
      @predicate_registry.unregister_types(*names)
      invalidate_filter_caches!
    end

    def unregister_types_from_group(group, *types)
      @predicate_registry.unregister_types_from_group(group, *types)
      invalidate_filter_caches!
    end

    private

    def validate_name!(name)
      unless (name.is_a?(String) || name.is_a?(Symbol)) && name.to_s.match?(Filters::Base::VALID_IDENTIFIER) &&
          name.to_s.length <= Filters::Base::MAX_IDENTIFIER_LENGTH
        raise ArgumentError, 'registration names must be valid identifiers'
      end
    end

    def arel_predicate_method(name, applies_to: [:property])
      receivers = Array(applies_to).map { |kind| arel_predicate_receiver(kind) }
      unless receivers.all? { |receiver| receiver.public_methods.include?(name.to_sym) }
        raise ArgumentError, "unknown Arel predicate #{name.inspect}: method is not publicly callable on the #{Array(applies_to).join(', ')} receiver"
      end

      receiver = receivers.first
      receiver.method(name.to_sym)
    rescue NameError
      raise ArgumentError, "unknown Arel predicate #{name.inspect}: method is not publicly callable on the #{Array(applies_to).join(', ')} receiver"
    end

    def arel_predicate_receiver(kind)
      case kind.to_sym
      when :association
        Arel::Table.new(:scry_registration)[:value].dup.tap do |attribute|
          attribute.extend(Predications::AssociationAttributeBehavior)
        end
      when :property, :computed, :aggregate
        Arel::Table.new(:scry_registration)[:value]
      else
        raise ArgumentError, "unsupported predicate receiver #{kind.inspect}"
      end
    end

    def validate_definition!(name, types, adapters)
      validate_name!(name)
      raise ArgumentError, 'types must be a nonempty Array' unless types.is_a?(Array) && !types.empty?
      types.each { |type| validate_name!(type) }
      unless adapters.nil? || (adapters.is_a?(Array) && !adapters.empty?)
        raise ArgumentError, 'adapters must be a nonempty Array or nil'
      end
      adapters&.each { |adapter| validate_name!(adapter) }
    end

    def validate_applies_to!(kinds)
      kinds = Array(kinds).map(&:to_sym)
      unless kinds.is_a?(Array) && !kinds.empty? && kinds.all? { |kind| PREDICATE_FILTER_KINDS.include?(kind) }
        raise ArgumentError,
          "applies_to must be a nonempty collection containing only #{PREDICATE_FILTER_KINDS.inspect}"
      end

      kinds.uniq.freeze
    rescue NoMethodError
      raise ArgumentError,
        "applies_to must be a nonempty collection containing only #{PREDICATE_FILTER_KINDS.inspect}"
    end

    def validate_association_predicate!(arel_predicate, applies_to)
      return unless Array(applies_to).include?(:association)
      return unless arel_predicate && ASSOCIATION_UNSUPPORTED_AREL_PREDICATES.include?(arel_predicate.to_sym)

      raise ArgumentError, "association predicates cannot use #{arel_predicate.inspect}; use membership predicates"
    end

    def validate_callback!(callback, counts, label)
      raise ArgumentError, "#{label} must be callable" unless callback.respond_to?(:call)
      parameters = callback.respond_to?(:parameters) ? callback.parameters : callback.method(:call).parameters
      if parameters.any? { |kind, _| kind == :keyreq }
        raise ArgumentError, "#{label} must not require keyword arguments"
      end
      return counts.first if callback.is_a?(Proc) && !callback.lambda?

      required = parameters.count { |kind, _| kind == :req }
      maximum = parameters.any? { |kind, _| kind == :rest } ? Float::INFINITY : parameters.count { |kind, _| %i[req opt].include?(kind) }
      count = counts.find { |size| size >= required && size <= maximum }
      if !count || parameters.any? { |kind, _| kind == :keyreq }
        raise ArgumentError, "#{label} must accept #{counts.join(' or ')} positional arguments"
      end
      count
    end

    def predicate_signature(callable, receiver:)
      parameters = predicate_parameters(callable).drop(receiver)
      positional = parameters.filter_map do |kind, name|
        case kind
        when :req then {name: name || :argument, kind: :required}
        when :opt then {name: name || :argument, kind: :optional}
        when :rest then {name: name || :arguments, kind: :rest}
        end
      end
      unless positional.length == parameters.length
        raise ArgumentError, 'predicate signatures must use positional arguments only'
      end

      required = positional.count { |parameter| parameter[:kind] == :required }
      rest = positional.any? { |parameter| parameter[:kind] == :rest }
      {parameters: positional.freeze, arguments: {min: required, max: rest ? nil : positional.length}.freeze}
    end

    def predicate_parameters(callable)
      return callable.parameters unless callable.is_a?(Proc)

      # Ordinary Procs report positional parameters as optional. Lambda-style
      # reflection preserves the required/optional distinction declared by the host.
      callable.parameters(lambda: true)
    rescue ArgumentError
      # Older Ruby lacks lambda-style Proc reflection; Method reflection retains
      # the same required/optional/rest signature without parsing source.
      signature_module = Module.new
      signature_module.define_method(:callback, &callable)
      signature_module.instance_method(:callback).parameters
    end

    def snapshot
      {
        predicate_registry: @predicate_registry.snapshot,
        aggregate_registry: @aggregate_registry.snapshot,
        filter_class_mappings: @filter_class_mappings.dup,
        invalid_filter_policy: @invalid_filter_policy, callback_error_policy: @callback_error_policy,
        diagnostic_logging: @diagnostic_logging, strict: @strict,
        max_filter_depth: @max_filter_depth, max_filter_nodes: @max_filter_nodes,
        max_filter_bytes: @max_filter_bytes, logger: @logger, log_context: @log_context
      }
    end

    def load_snapshot(state)
      @revision = 0
      @predicate_registry = PredicateRegistry.new
      @predicate_registry.restore(state[:predicate_registry])
      @aggregate_registry = AggregateRegistry.new(type_registry: @predicate_registry.type_registry)
      @aggregate_registry.restore(state[:aggregate_registry])
      state.except(:predicate_registry, :aggregate_registry).each do |name, value|
        instance_variable_set(:"@#{name}", value)
      end
      @settings_locked = false
    end

    def ensure_settings_mutable!
      return unless settings_locked?

      raise FilterError,
        'Scry settings are locked; use with_temporary_settings for scoped changes'
    end

    def positive_limit(value, name)
      limit = Integer(value)
      raise ArgumentError, "#{name} must be >= 1" unless limit.positive?
      limit
    end

    def compound_entries(name:, custom_predicate:, formatter:, validator:, types:, applies_to:, any_name:, all_name:, adapters: nil, prepare_arguments: nil)
      if custom_predicate
        combine = lambda do |attribute, values, conjunction|
          values = Array(values)
          nodes = values.map { |value| custom_predicate.call(attribute, value) }
          nodes.reduce { |combined, node| conjunction ? combined.and(node) : combined.or(node) } || Compatibility.truth(conjunction)
        end
        compound_validator = lambda do |values|
          raise FilterError, 'Scry: compound predicate value must be an Array' unless values.is_a?(Array)
          validator ? values.map { |value| validator.call(value) } : values
        end
        return [
          { name: any_name, custom_predicate: ->(attribute, values) { combine.call(attribute, values, false) },
            **predicate_signature(compound_validator, receiver: 0), formatter:, validator: compound_validator,
            prepare_arguments:, types:, applies_to:, adapters: },
          { name: all_name, custom_predicate: ->(attribute, values) { combine.call(attribute, values, true) },
            **predicate_signature(compound_validator, receiver: 0), formatter:, validator: compound_validator,
            prepare_arguments:, types:, applies_to:, adapters: }
        ]
      end

      [
        {
        name: any_name,
        arel_predicate: "#{name}_any".to_sym,
        **predicate_signature(arel_predicate_method("#{name}_any", applies_to:), receiver: 0),
        formatter:,
        validator:,
        prepare_arguments:,
        types:,
        applies_to:,
        adapters:
        },
        {
        name: all_name,
        arel_predicate: "#{name}_all".to_sym,
        **predicate_signature(arel_predicate_method("#{name}_all", applies_to:), receiver: 0),
        formatter:,
        validator:,
        prepare_arguments:,
        types:,
        applies_to:,
        adapters:
        }
      ]
    end

    def setup_defaults
      setup_default_types
      setup_default_predicates
      setup_default_aggregates
    end

    def setup_default_types
      register_types(:numerical,          :integer, :float, :decimal, :interval, :binary, :temporal)
      register_types(:textual,            :string, :text, :binary, :enum)
      register_types(:temporal,           :date, :time, :datetime, :timestamp)
      register_types(:boolean,            :boolean)
      register_types(:association,        :many_association, :single_association)
      register_types(:many_association,   :has_many, :has_and_belongs_to_many)
      register_types(:single_association, :has_one, :belongs_to)
      register_types(:summable,           :integer, :float, :decimal)
      register_types(:orderable,          :numerical, :temporal, :textual)
      register_types(:identifier,         :uuid, :primary_key)
      register_types(:network,            :inet, :cidr)
      register_types(:array,              :string_array, :integer_array, :text_array)
      register_types(:json,               :jsonb)
      register_types(:range,              :daterange, :tsrange, :tstzrange, :int4range, :int8range, :numrange)
    end

    def setup_default_predicates
      setup_global_predicates
      setup_numerical_predicates
      setup_temporal_predicates
      setup_textual_predicates
      setup_boolean_predicates
      setup_json_predicates
      setup_association_predicates
      setup_network_predicates
      setup_array_predicates
      setup_range_predicates
    end

    def setup_global_predicates
      expression_kinds = %i[property computed aggregate]
      value_kinds = %i[property computed aggregate]
      register_predicate :eq_nil, types: %i[temporal numerical textual identifier network array range], applies_to: expression_kinds, compounds: false do |attr|
        attr.eq(nil)
      end
      register_predicate :not_eq_nil, types: %i[temporal numerical textual identifier network array range], applies_to: expression_kinds, compounds: false do |attr|
        attr.not_eq(nil)
      end
      types = %i[numerical textual temporal json identifier network array range]
      register_predicate(:eq, types:, applies_to: value_kinds, compounds: true)
      register_predicate(:not_eq, types:, applies_to: value_kinds, compounds: true)
    end

    def setup_numerical_predicates
      expression_kinds = %i[property computed aggregate]
      register_predicate(:between, compounds: false, types: %i[numerical], applies_to: expression_kinds) do |attribute, lower, upper|
        Compatibility.range_condition(attribute, lower, upper)
      end
      register_predicate(:not_between, compounds: false, types: %i[numerical], applies_to: expression_kinds) do |attribute, lower, upper|
        Compatibility.negate(Compatibility.range_condition(attribute, lower, upper))
      end
      register_predicate(:gt, compounds: false, types: %i[numerical], applies_to: expression_kinds)
      register_predicate(:lt, compounds: false, types: %i[numerical], applies_to: expression_kinds)
      register_predicate(:gteq, compounds: false, types: %i[numerical], applies_to: expression_kinds)
      register_predicate(:lteq, compounds: false, types: %i[numerical], applies_to: expression_kinds)
    end

    def setup_temporal_predicates
      # Parse before predicate construction so invalid duration input follows the
      # configured filter-error path instead of leaking parser exceptions.
      duration_validator = ->(value) {
        case value
        when ActiveSupport::Duration then value
        when String
          raise Scry::InvalidOperandError,
            "duration string too long (#{value.length} chars, max 100)" if value.length > 100
          ActiveSupport::Duration.parse(value)
        else raise Scry::InvalidOperandError,
          "expected an ISO 8601 duration string or ActiveSupport::Duration, got #{value.class}"
        end
      }
      ranges = {
        within: ->(duration) { now = Time.current; duration.ago(now)..duration.since(now) },
        within_next: ->(duration) { now = Time.current; now..duration.since(now) },
        within_previous: ->(duration) { now = Time.current; duration.ago(now)..now }
      }
      [false, true].each do |negative|
        ranges.each do |name, formatter|
          register_predicate(negative ? :"not_#{name}" : name, compounds: false, types: [:temporal], applies_to: %i[property computed aggregate],
            arel_predicate: negative ? :not_between : :between, validator: duration_validator, formatter: formatter)
        end
      end
    end

    def setup_textual_predicates
      expression_kinds = %i[property computed aggregate]
      # Keep registration order stable because discovery presents this order to clients.
      register_textual_predicate(:matches, prefix: '%', suffix: '%', applies_to: expression_kinds)
      register_textual_predicate(:starts_with, prefix: '', suffix: '%', applies_to: expression_kinds)
      register_textual_predicate(:ends_with, prefix: '%', suffix: '', applies_to: expression_kinds)
      register_textual_predicate(:does_not_match, prefix: '%', suffix: '%', applies_to: expression_kinds, negative: true)
      register_textual_predicate(:does_not_start_with, prefix: '', suffix: '%', applies_to: expression_kinds, negative: true)
      register_textual_predicate(:does_not_end_with, prefix: '%', suffix: '', applies_to: expression_kinds, negative: true)
      # Regexp predicates (matches_regexp, does_not_match_regexp) are not registered
      # by default for safety. Register them manually if needed:
      #   Scry.configure do |config|
      #     config.register_predicate(:matches_regexp, types: %i[textual])
      #     config.register_predicate(:does_not_match_regexp, types: %i[textual])
      #   end
    end

    def register_textual_predicate(name, prefix:, suffix:, applies_to:, negative: false)
      scalar = lambda do |value|
        if value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(Range)
          raise FilterError, 'Scry: predicate requires a scalar operand'
        end
        value
      end
      collection = lambda do |value|
        raise FilterError, 'Scry: compound predicate value must be an Array' unless value.is_a?(Array)

        value
      end
      formatter = ->(value) { "#{prefix}#{ActiveRecord::Base.sanitize_sql_like(value.to_s)}#{suffix}" }
      match = lambda do |attribute, value|
        negative ? attribute.does_not_match(value, "\\") : attribute.matches(value, "\\")
      end
      combine = lambda do |attribute, values, conjunction|
        nodes = values.map { |value| match.call(attribute, value) }
        nodes.reduce { |combined, node| conjunction ? combined.and(node) : combined.or(node) } || Compatibility.truth(conjunction)
      end

      register_predicate(name, types: %i[textual], applies_to:, compounds: false, validator: scalar, formatter:, &match)
      register_predicate("#{name}_any", types: %i[textual], applies_to:, compounds: false, validator: collection, formatter:) do |attribute, values|
        combine.call(attribute, values, false)
      end
      register_predicate("#{name}_all", types: %i[textual], applies_to:, compounds: false, validator: collection, formatter:) do |attribute, values|
        combine.call(attribute, values, true)
      end
    end

    def setup_boolean_predicates
      expression_kinds = %i[property computed aggregate]
      register_predicate(:eq_true, compounds: false, types: %i[boolean], applies_to: expression_kinds) { |attr| attr.eq(true) }
      register_predicate(:eq_false, compounds: false, types: %i[boolean], applies_to: expression_kinds) { |attr| attr.eq(false) }
    end

    def setup_json_predicates
      register_predicate(:contains, types: %i[json], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('@>', attr, Compatibility.quoted(value, attr))
      end
    end

    def setup_association_predicates
      %i[has_any not_has_any has_all not_has_all only_has_any only_has_all].each do |name|
        types = %i[has_any not_has_any].include?(name) ? %i[single_association many_association] : [:many_association]
        register_predicate(name, types:, applies_to: [:association], compounds: false, arel_predicate: name)
      end
    end

    def setup_network_predicates
      register_predicate(:inet_contains, types: %i[network], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('>>', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:inet_contained_within, types: %i[network], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('<<', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:inet_overlaps, types: %i[network], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('&&', attr, Compatibility.quoted(value, attr))
      end
    end

    def setup_array_predicates
      register_predicate(:array_contains, types: %i[array], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('@>', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:array_contained_by, types: %i[array], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('<@', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:array_overlaps, types: %i[array], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('&&', attr, Compatibility.quoted(value, attr))
      end
    end

    def setup_range_predicates
      register_predicate(:range_contains, types: %i[range], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('@>', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:range_contained_by, types: %i[range], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('<@', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:range_overlaps, types: %i[range], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('&&', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:range_strictly_left_of, types: %i[range], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('<<', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:range_strictly_right_of, types: %i[range], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('>>', attr, Compatibility.quoted(value, attr))
      end
      register_predicate(:range_adjacent_to, types: %i[range], applies_to: %i[property computed aggregate], compounds: false, adapters: [:postgresql]) do |attr, value|
        Arel::Nodes::InfixOperation.new('-|-', attr, Compatibility.quoted(value, attr))
      end
    end

    def setup_default_aggregates
      register_aggregate(:count, types: [:all], result_type: :integer, empty_value: 0, property: false, composite_distinct: true) do |attr, distinct|
        attr.count(distinct)
      end
      register_aggregate(:sum, types: [:summable]) do |attr, distinct|
        Arel::Nodes::Sum.new([attr]).tap { |node| node.distinct = distinct }
      end
      register_aggregate(:avg, types: [:summable]) do |attr, distinct|
        Arel::Nodes::Avg.new([attr]).tap { |node| node.distinct = distinct }
      end
      register_aggregate(:min, types: [:orderable], result_type: :property) { |attr, _| attr.minimum }
      register_aggregate(:max, types: [:orderable], result_type: :property) { |attr, _| attr.maximum }
    end
  end
end
