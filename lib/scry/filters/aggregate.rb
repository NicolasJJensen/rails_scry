# frozen_string_literal: true

module Scry
  module Filters
    class Aggregate < Base
      def property
        @_property ||= safe_to_sym(@filter[:association])
      end

      def apply
        return failure_from_reported_error if depth_exceeded?
        return failure('Scry: aggregate filter must be a Hash', code: :invalid_aggregate_filter) unless @filter.is_a?(Hash)
        return failure('Scry: aggregate requires an association and predicate', code: :missing_association) unless @filter[:association] && @filter[:predicate]
        return failure('Scry: include_zero? is no longer supported', code: :invalid_aggregate_filter) if @filter.key?(:include_zero?)
        name = property
        return failure_from_reported_error unless name
        return failure('Scry: invalid or missing association', code: :unknown_association) unless @model.reflect_on_association(name)
        return failure('Scry: disallowed aggregate association', category: :permission_denied, code: :aggregate_denied, relation: @scope.none) unless valid_association?

        query = AssociationQuery.new(@model, property, context: @context, target_type: @filter[:target_type])
        child = query.child_model
        return failure("Scry: model #{child.name} not allowed", category: :permission_denied, code: :aggregate_denied, relation: @scope.none) unless validate_model_filterable(child)
        aggregate = safe_to_sym(@filter[:aggregate] || :count)
        return failure_from_reported_error unless aggregate
        definition = Scry.configuration.aggregate_registry.by_name(aggregate)
        return failure('Scry: invalid aggregate or missing builder', code: :unknown_aggregate) unless definition && definition[:builder]
        return failure('Scry: aggregate is not supported by this adapter', code: :unsupported_aggregate) unless Compatibility.supported?(@model, definition)
        field = @filter[:property]&.to_s
        if definition[:property]
          unless field && child.column_names.include?(field)
            return failure('Scry: aggregate requires a valid property', code: :invalid_aggregate_property)
          end
          unless child.scry_permissions.allowed_properties(@context).include?(field.to_sym)
            return failure('Scry: disallowed aggregate property', category: :permission_denied, code: :aggregate_denied, relation: @scope.none)
          end
        end
        allowed = @model.scry_permissions.allowed_aggregates(
          @context, propagate_callback_failure: true
        ).dig(property.to_s, aggregate.to_s)
        unless allowed == true || (allowed.respond_to?(:include?) && allowed.include?(field))
          return failure('Scry: disallowed aggregate', category: :permission_denied, code: :aggregate_denied, relation: @scope.none)
        end
        result_type = definition[:result_type] == :property ? Compatibility.property_type(child, field) : definition[:result_type]
        unless @model.scry_permissions.allowed_aggregate_predicates(@context, type: result_type).include?(predicate)
          return failure('Scry: disallowed aggregate predicate', category: :permission_denied, code: :aggregate_denied, relation: @scope.none)
        end
        predicate_obj = Scry.configuration.predicate_registry.by_name(predicate)
        return failure('Scry: unknown aggregate predicate', code: :unknown_predicate) unless predicate_obj
        unless predicate_applicable?(predicate_obj, kind: :aggregate, result_type:)
          return failure('Scry: aggregate predicate is not applicable to this result type', category: :permission_denied, code: :aggregate_denied, relation: @scope.none)
        end
        relation_fields = definition[:property] ? [field] : []
        related = query.scoped_relation(fields: relation_fields)
        unless @filter[:scoping].nil?
          return failure('Scry: aggregate scoping must be a Hash', code: :invalid_scoping) unless @filter[:scoping].is_a?(Hash)
          scoped = Group.new(model: child, filter: @filter[:scoping], context: @context, depth: @depth + 1)
            .with_path([*(@path || []), :scoping]).apply
          if scoped.failed?
            return Scry::Result.new(status: :failed, relation: @scope, diagnostics: scoped.diagnostics)
          end
          related = query.scoped_relation(scoped.relation, fields: relation_fields)
        end
        distinct = BOOLEAN_TYPE.cast(@filter[:distinct?]) == true
        return failure('Scry: aggregate does not support distinct', code: :unsupported_distinct) if distinct && !definition[:distinct]
        composite_count = distinct && definition[:composite_distinct] && query.child_keys.length > 1
        if composite_count
          projection = [*query.parent_keys_for(related), *query.child_keys_for(related)]
          projection << query.child_attribute_for(related, field) if definition[:property]
          related = related.select(*projection).distinct
          distinct = false
        end
        attribute = if definition[:property]
          query.child_attribute_for(related, field)
        else
          # Composite distinct counts have already projected every child key
          # and deduplicated those complete identities above. The count
          # builder still accepts one non-null column as its scalar operand.
          query.child_keys_for(related).fetch(0)
        end
        aggregate_node = invoke_extension('aggregate builder') { definition[:builder].call(attribute, distinct) }
        return failure('Scry: aggregate builder must return an Arel node', code: :invalid_aggregate_node) unless valid_arel_node?(aggregate_node)
        comparison = aggregate_comparison(predicate_obj, aggregate_node, child, definition[:result_type], field)
        return failure_from_reported_error unless comparison
        condition = query.membership(
          related.group(*query.parent_keys_for(related)).having(comparison),
          owner_relation: @scope
        )
        if !definition[:empty_value].nil?
          # COUNT defines an empty set as zero; other aggregates keep NULL
          # unless their registration supplies an empty-set value.
          empty_comparison = aggregate_comparison(
            predicate_obj,
            Arel::Nodes.build_quoted(definition[:empty_value]),
            child,
            definition[:result_type],
            field
          )
          return failure_from_reported_error unless empty_comparison
          condition = condition.or(
            Compatibility.negate(query.membership(related, owner_relation: @scope)).and(empty_comparison)
          )
        end
        success(apply_negation_if_needed(@scope.where(condition)))
      rescue Scry::ReportedError => error
        failure_from_reported_error(error)
      rescue Scry::FilterError => e
        raise if e.is_a?(Scry::ModelScopeError)

        failure(e.message)
      end

      private

      def aggregate_comparison(definition, attribute, child, result_type, field)
        args = prepare_predicate_arguments(definition, predicate_args(definition), array_aware: true)
        return nil if args.equal?(PIPELINE_FAILED)
        prepared_args = prepare_registered_arguments(definition, args)
        return nil if prepared_args.equal?(PIPELINE_FAILED)
        args = prepared_args || args
        args = args.map { |value| Compatibility.cast_aggregate_operand(child, result_type, field, value) }
        unless definition[:custom_predicate] && !definition[:adapters]
          args = args.map do |value|
            value.is_a?(Range) || value.is_a?(Array) || value.is_a?(Arel::Nodes::Node) ? value : Arel::Nodes.build_quoted(value)
          end
        end
        build_predicate_node(definition, attribute, args)
      end

    end
  end
end
