# frozen_string_literal: true

module Scry
  module Filters
    class Base
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new.freeze
      MAX_IDENTIFIER_LENGTH = 255
      VALID_IDENTIFIER = /\A[a-zA-Z_]\w*[?!]?\z/
      PIPELINE_FAILED = Object.new.freeze
      NATIVE_AREL_PREDICATES = %i[eq not_eq gt lt gteq lteq matches does_not_match].freeze

      def initialize(model:, filter:, context:, depth: 0)
        if model.is_a?(ActiveRecord::Relation)
          @model = model.klass
          @scope = model
        else
          @model = model
          @scope = model.all
        end
        @filter = filter
        @context = context
        @depth = depth
        @source = @scope.from_clause.value if @scope.from_clause.value.is_a?(Arel::Nodes::TableAlias)
      end

      def with_source(source)
        @source = source
        self
      end

      def with_path(path)
        @path = path
        self
      end

      def source_attribute(name)
        (@source || @model.arel_table)[name]
      end

      def source_relation
        relation = @scope
        return relation unless @source

        relation = relation.from(@source)
        default_projection = relation.select_values.empty? || relation.select_values == [Arel.star]
        default_projection ? relation.reselect(@source[Arel.star]) : relation
      end

      def depth_exceeded?
        max = Scry.configuration.max_filter_depth
        if @depth >= max
          handle_error("Scry: filter depth #{@depth} exceeds max_filter_depth (#{max}), ignoring")
          true
        else
          false
        end
      end

      def predicate
        @_predicate ||= safe_to_sym(@filter[:predicate])
      end

      def property
        raise NotImplementedError, "#{self.class.name} must implement the abstract method #property"
      end

      def apply
        raise NotImplementedError, "#{self.class.name} must implement the abstract method #apply"
      end

      # Compile a registered child while retaining the caller's scope and path.
      # Custom filters use this entry point so nested filters receive the same
      # validation and selection semantics as built-in groups.
      def compile_nested_filter(filter_definition, index: nil, path: nil)
        nested_path = path || [*diagnostic_path, :filters, index].compact
        unless filter_definition.is_a?(Hash)
          return failure('Scry: filter element is not a Hash', path: nested_path, code: :invalid_filter_element)
        end

        begin
          filter_definition = Scry::Input.normalize(filter_definition)
        rescue Scry::FilterError => error
          return failure(error.message, path: nested_path)
        end

        klass = Scry.configuration.filter_class_mappings[filter_definition[:type]]
        return failure('Scry: unknown filter type', path: nested_path, code: :unknown_filter_type) unless klass

        branch_scope = @scope.except(:order, :limit, :offset)
        selection_base_relation = @selection_base_relation || branch_scope
        nested_scope = authorized_scope(selection_base_relation)
        instance = klass.new(model: nested_scope, filter: filter_definition, context: @context, depth: @depth + 1)
        instance.with_path(nested_path) if instance.respond_to?(:with_path)
        instance.with_selection_base_relation(selection_base_relation) if instance.respond_to?(:with_selection_base_relation)
        instance.with_source(@source) if @source && instance.respond_to?(:with_source)
        result = instance.apply

        unless result.is_a?(Scry::Result) && result.relation.is_a?(ActiveRecord::Relation) && result.relation.klass == @model
          return failure('Scry: filter classes must return a result for the current model', path: nested_path, code: :invalid_filter_result)
        end

        result
      rescue Scry::ReportedError => error
        failure_from_reported_error(error)
      end

      def valid_property?
        @model.scry_permissions.allowed_properties(@context).include?(property)
      end

      def valid_predicate?
        @model.scry_permissions.allowed_property_predicates(@context)[property]&.include?(predicate)
      end

      def predicate_applicable?(definition, kind:, result_type: nil)
        return false unless Array(definition[:applies_to]).map(&:to_sym).include?(kind.to_sym)
        return true unless result_type

        registry = Scry.configuration.predicate_registry
        Array(definition[:types]).any? do |type|
          registry.types_in_group(type).map(&:to_sym).include?(result_type.to_sym)
        end
      end

      def valid_association?
        @model.scry_permissions.allowed_associations(@context).include?(property)
      end

      def run_predicate(args)
        predicate_obj = Scry.configuration.predicate_registry.by_name(predicate)
        return handle_error("Scry: unknown predicate #{predicate.inspect}") unless predicate_obj
        validate_predicate_args!(predicate_obj, args)

        tokens = [predicate]
        tokens |= Array(predicate_obj[:types]).map(&:to_sym)

        transforms = applicable_property_transforms(property, tokens)

        args = prepare_predicate_arguments(predicate_obj, args, transforms:, array_aware: true, property_range: true)
        return nil if args.equal?(PIPELINE_FAILED)

        custom_predicate = predicate_obj[:custom_predicate]
        # Ordinary custom callbacks consume Ruby values. Adapter-backed
        # callbacks and callbacks with an explicit value-node transform retain
        # the native Arel operand contract.
        raw_custom_operand = custom_predicate && !predicate_obj[:adapters] && transforms[:value_node].empty?
        source_attr = source_attribute(property)
        # Argument preparation needs the model-backed attribute for type
        # serialization. The rendered predicate still uses source_attr, which
        # may be an aliased derived source owned by the caller's relation.
        prepared_args = prepare_registered_arguments(predicate_obj, args)
        return nil if prepared_args.equal?(PIPELINE_FAILED)
        attr = source_attr
        native = predicate_obj[:adapters]
        json_property = %i[json jsonb].include?(Compatibility.property_type(@model, property).to_s.to_sym)
        will_use_nodes = !raw_custom_operand && (transforms[:value_node].present? || predicate_obj[:adapters] || prepared_args || json_property)
        structured_operand = json_property || !predicate.to_s.end_with?('_any', '_all')
        node_args = prepared_args || if json_property && predicate.to_s.end_with?('_any', '_all')
          [Array(args.first).map { |value| to_arel_node(value, attribute: attr, structured: true) }]
        else
          args.map do |value|
            value = Array.wrap(value) if native && Compatibility.property_type(@model, property) == :array && predicate.to_s.start_with?('array_')
            native ? Compatibility.native_operand(@model, property, predicate, value, attr) : to_arel_node(value, attribute: attr, structured: structured_operand)
          end
        end
        node_args = node_args.map { |node| apply_value_node_transforms(node, transforms[:value_node]) } if will_use_nodes

        attr = source_attribute(property)
        if Compatibility.adapter(@model) == 'postgresql' && Compatibility.property_type(@model, property).to_s == 'json'
          attr = Compatibility.cast(attr, 'jsonb')
        end
        attr = apply_attribute_transforms(attr, transforms[:attribute])

        # Custom callbacks receive validated Ruby operands unless their existing
        # adapter/value-node contract explicitly asks for Arel nodes.
        dispatch_args = if raw_custom_operand
          prepared_args || args
        elsif (predicate_obj[:arel_predicate] && NATIVE_AREL_PREDICATES.include?(predicate_obj[:arel_predicate].to_sym)) || will_use_nodes
          node_args
        else
          args
        end
        node = build_predicate_node(predicate_obj, attr, dispatch_args)
        return nil unless node
        source_relation.where(node)
      rescue Scry::ReportedError
        raise
      rescue Scry::FilterError => e
        handle_error(e.message)
      end

      protected

      attr_reader :filter, :context, :model, :depth

      def scope
        @scope
      end

      def diagnostic_path
        @path || []
      end

      def success(relation)
        Scry::Result.success(relation)
      end

      def partial(relation, diagnostics)
        Scry::Result.partial(relation, diagnostics:)
      end

      def failure(message, category: :invalid_filter, code: :invalid_filter, relation: @scope, path: @path || [])
        Scry::Result.failure(
          relation:,
          message:,
          category:,
          code:,
          path:
        )
      end

      def failure_from_reported_error(error = nil, relation: @scope)
        return failure('Scry: filter failed', relation:) unless error

        Scry::Result.new(status: :failed, relation:, diagnostics: [error.diagnostic])
      end

      def handle_error(message, path: @path || [], code: :invalid_filter)
        diagnostic = Scry::Diagnostic.new(category: :invalid_filter, code:, path:, message:)
        raise Scry::ReportedError, diagnostic
      end

      def handle_permission_denial(message)
        diagnostic = Scry::Diagnostic.new(category: :permission_denied, code: :permission_denied, path: @path || [], message:)
        raise Scry::ReportedError, diagnostic
      end

      def apply_negation_if_needed(result)
        return result unless result && BOOLEAN_TYPE.cast(@filter[:negate]) == true

        @scope.where(Compatibility.negate(Compatibility.condition(result, outer_relation: @scope)))
      end

      def validate_model_filterable(model)
        unless model.respond_to?(:scry_permissions)
          handle_error("Scry: model #{model.name} does not include Filterable")
          return false
        end

        unless model.model_allowed?(@context)
          handle_permission_denial("Scry: model #{model.name} not allowed")
          return false
        end

        true
      end

      def authorized_scope(relation)
        candidate = Compatibility.key_projection(relation, @model)
        source = relation.from_clause.value
        scope = if source.is_a?(Arel::Nodes::TableAlias)
          @model.unscoped.from(source).select(Arel.star)
        else
          @model.unscoped
        end
        scope.where(
          Compatibility.key_membership(
            Compatibility.key_attributes(
              @model,
              relation: source.is_a?(Arel::Nodes::TableAlias) ? source : @model.arel_table
            ),
            candidate
          )
        )
      end

      private

      def predicate_args(definition)
        args = @filter.key?(:args) ? @filter[:args] : []
        unless args.is_a?(Array)
          handle_error('Scry: predicate args must be an Array', code: :invalid_filter_args)
        end
        validate_predicate_args!(definition, args)
        args
      end

      def validate_predicate_args!(definition, args)
        minimum = definition.dig(:arguments, :min)
        maximum = definition.dig(:arguments, :max)
        unless args.is_a?(Array) && args.length >= minimum && (maximum.nil? || args.length <= maximum)
          handle_error(
            "Scry: predicate #{predicate.inspect} expects #{argument_requirement(definition)}",
            code: :invalid_filter_args
          )
        end
      end

      def argument_requirement(definition)
        minimum = definition.dig(:arguments, :min)
        maximum = definition.dig(:arguments, :max)
        return "at least #{minimum} argument#{minimum == 1 ? '' : 's'}" if maximum.nil?
        return "#{minimum} argument#{minimum == 1 ? '' : 's'}" if minimum == maximum

        "between #{minimum} and #{maximum} arguments"
      end

      def prepare_predicate_arguments(definition, args, transforms: nil, array_aware: false, property_range: false, validate_shape: true)
        validate_predicate_args!(definition, args)
        args.map do |value|
          validate_operand_shape!(definition, value) if validate_shape
          value = apply_predicate_validator(definition, value)
          return PIPELINE_FAILED if value.equal?(PIPELINE_FAILED)
          value = apply_value_transforms(value, transforms[:value]) if transforms
          value = apply_predicate_formatter(definition, value, array_aware:)
          return PIPELINE_FAILED if value.equal?(PIPELINE_FAILED)
          property_range && value.is_a?(Range) ? Compatibility.property_range(@model, property, value) : value
        end
      end

      def prepare_registered_arguments(definition, args)
        return nil unless definition[:prepare_arguments]

        prepared = invoke_extension('predicate argument preparation') do
          definition[:prepare_arguments].call(args)
        end
        unless prepared.is_a?(Array)
          handle_error('Scry: predicate argument preparation must return an Array', code: :invalid_prepared_arguments)
        end
        if prepared.any? { |value| arel_operand?(value) }
          handle_error('Scry: predicate argument preparation must return Ruby values', code: :invalid_prepared_arguments)
        end
        prepared
      end

      def arel_operand?(value, seen = {})
        return true if value.is_a?(Arel::Nodes::Node) || value.is_a?(Arel::Nodes::SqlLiteral) || value.is_a?(Arel::Attributes::Attribute)
        return false if value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false || value.is_a?(Symbol)
        return false if value.is_a?(ActiveRecord::Relation) || value.is_a?(ActiveRecord::Base)
        return false if seen[value.object_id]

        seen[value.object_id] = true
        case value
        when Array
          value.any? { |item| arel_operand?(item, seen) }
        when Range
          arel_operand?(value.begin, seen) || arel_operand?(value.end, seen)
        when Hash
          value.any? { |key, item| arel_operand?(key, seen) || arel_operand?(item, seen) }
        else
          false
        end
      end

      def validate_operand_shape!(definition, value)
        method = definition[:arel_predicate].to_s
        if method.end_with?('_any', '_all')
          raise FilterError, 'Scry: compound predicate value must be an Array' unless value.is_a?(Array)
        elsif %w[matches does_not_match gt lt gteq lteq].include?(method)
          if value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(Range)
            raise FilterError, 'Scry: predicate requires a scalar operand'
          end
        end
      end

      def safe_to_sym(str)
        str = str.to_s
        if str.length > MAX_IDENTIFIER_LENGTH
          return handle_error("Scry: identifier too long (#{str.length} chars, max #{MAX_IDENTIFIER_LENGTH}): #{str[0, 50].inspect}")
        end
        unless str.match?(VALID_IDENTIFIER)
          return handle_error("Scry: identifier contains invalid characters: #{str[0, 50].inspect}")
        end
        str.to_sym
      end

      def apply_predicate_validator(predicate_obj, value)
        return value unless predicate_obj[:validator]
        invoke_extension('predicate validator') { predicate_obj[:validator].call(value) }
      end

      def apply_predicate_formatter(predicate_obj, value, array_aware: false)
        return value unless predicate_obj[:formatter]
        if array_aware && value.is_a?(Array)
          value.map { |v| invoke_extension('predicate formatter') { predicate_obj[:formatter].call(v) } }
        else
          invoke_extension('predicate formatter') { predicate_obj[:formatter].call(value) }
        end
      end

      def build_predicate_node(predicate_obj, attr, args)
        unless Compatibility.supported?(@model, predicate_obj)
          return handle_error("Scry: predicate is not supported by this adapter")
        end

        # Splat explicit args so Ruby keeps optional defaults; nested
        # collections remain one argument for collection predicates.
        node = if predicate_obj[:arel_predicate]
          begin
            attr.public_send(predicate_obj[:arel_predicate], *args)
          rescue NoMethodError
            return handle_error("Scry: Arel predicate #{predicate_obj[:arel_predicate].inspect} failed")
          end
        elsif predicate_obj[:custom_predicate]
          invoke_extension('custom predicate') { predicate_obj[:custom_predicate].call(attr, *args) }
        else
          return handle_error("Scry: predicate #{predicate.inspect} has no arel_predicate or custom_predicate")
        end

        unless valid_arel_node?(node)
          return handle_error("Scry: predicate #{predicate.inspect} returned invalid node")
        end

        node
      end

      def valid_arel_node?(node)
        node.is_a?(Arel::Nodes::Node)
      end

      def invoke_extension(label, &block)
        Scry.invoke_callback(label:, model: @model, context: @context, path: @path || [], &block)
      end

      def applicable_property_transforms(property, tokens)
        chain = @model.scry_permissions[:property_transforms]
        return { attribute: [], value: [], value_node: [] } unless chain

        perms = chain.permissions.to_a
        return { attribute: [], value: [], value_node: [] } if perms.empty?

        property = property.to_sym

        matches = perms.select do |perm|
          next false unless perm[:property].to_sym == property
          only = Array(perm[:only])
          exc = Array(perm[:except])
          only_ok = only.empty? || !(tokens & only).empty?
          except_hit = !(tokens & exc).empty?
          only_ok && !except_hit
        end

        specificity_of = lambda do |perm|
          only = Array(perm[:only])
          if only.include?(predicate)
            :predicate
          elsif !(tokens - [predicate] & only).empty?
            :type
          else
            :global
          end
        end

        buckets = { attribute: [], value: [], value_node: [] }
        matches.each do |perm|
          spec = specificity_of.call(perm)
          Array(perm[:on] || [:attribute, :value_node]).each do |target|
            target = target.to_sym
            next unless buckets.key?(target)
            buckets[target] << { spec:, block: perm[:block] }
          end
        end

        order = { predicate: 0, type: 1, global: 2 }
        buckets.transform_values! do |arr|
          arr.sort_by { |e| order[e[:spec]] }
        end
        buckets
      end

      def apply_attribute_transforms(attr, transforms)
        apply_transforms(attr, transforms, label: 'attribute', map_arrays: false)
      end

      def apply_value_transforms(value, transforms)
        apply_transforms(value, transforms, label: 'value', map_arrays: true)
      end

      def apply_value_node_transforms(node_or_nodes, transforms)
        apply_transforms(node_or_nodes, transforms, label: 'value_node', map_arrays: true)
      end

      def apply_transforms(operand, transforms, label:, map_arrays:)
        return operand if transforms.nil? || transforms.empty?
        if map_arrays && operand.is_a?(Array)
          return operand.map { |el| apply_transforms(el, transforms, label: label, map_arrays: true) }
        end
        transforms.reduce(operand) do |acc, t|
          invoke_extension("#{label} transform") { t[:block].call(acc, @context) }
        end
      end

      def to_arel_node(val, attribute: nil, structured: true)
        if !@source && attribute && attribute.respond_to?(:name) && @model.column_names.include?(attribute.name.to_s)
          type = @model.type_for_attribute(attribute.name.to_s)
          serialized = Compatibility.serialize_property_value(@model, attribute.name, val)
          serialized_collection = structured && val.is_a?(Array)
          if val.is_a?(Hash) || serialized_collection
            node = Compatibility.quoted(serialized, nil)
            return Compatibility.cast(node, 'jsonb') if %i[json jsonb].include?(type.type)
            return node
          end
        end
        if val.is_a?(Range)
          type = @model.type_for_attribute(property.to_s)
          first = val.begin.nil? ? nil : type.serialize(val.begin)
          last = val.end.nil? ? nil : type.serialize(val.end)
          Range.new(first, last, val.exclude_end?)
        elsif val.is_a?(Array)
          val.map { |v| to_arel_node(v, attribute: attribute) }
        elsif val.is_a?(Arel::Nodes::Node)
          val
        else
          value = if !@source && attribute && attribute.respond_to?(:name) && @model.column_names.include?(attribute.name.to_s)
            Compatibility.serialize_property_value(@model, attribute.name, val)
          else
            val
          end
          column_attribute = !@source && attribute && attribute.respond_to?(:name) && @model.column_names.include?(attribute.name.to_s)
          Arel::Nodes.build_quoted(value, column_attribute ? nil : attribute)
        end
      end
    end
  end
end
