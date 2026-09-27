# frozen_string_literal: true

module Scry
  module Filters
    class Computed < Base
      def apply
        return failure_from_reported_error if depth_exceeded?
        unless @filter.is_a?(Hash) && @filter[:expression].is_a?(Hash)
          return failure('Scry: computed filter requires an expression', code: :invalid_expression, path: @filter.is_a?(Hash) ? field_path(:expression) : diagnostic_path)
        end
        return failure('Scry: computed filter has missing :predicate key', code: :missing_predicate, path: field_path(:predicate)) unless @filter[:predicate]

        predicate_name = safe_to_sym(@filter[:predicate], field: :predicate)
        predicate_obj = Scry.configuration.predicate_registry.by_name(predicate_name)
        return failure("Scry: unknown predicate #{predicate_name.inspect}", code: :unknown_predicate, path: field_path(:predicate)) unless predicate_obj
        expression = Expression.compile(
          @model,
          @filter[:expression],
          allowed_properties: @model.scry_permissions.allowed_properties(@context),
          source: @source,
          path: field_path(:expression)
        )
        result_type = with_error_path(:expression) { Expression.result_type(@model, @filter[:expression]) }
        unless predicate_applicable?(predicate_obj, kind: :computed, result_type:)
          return failure('Scry: computed predicate is not applicable to this expression', category: :permission_denied, code: :predicate_denied, relation: @scope.none, path: field_path(:predicate))
        end
        leaves = expression_properties(@filter[:expression])
        allowed_predicates = @model.scry_permissions.allowed_expression_predicates(@context, leaves)
        permitted = allowed_predicates.include?(predicate_name) &&
          leaves.all? { |property| @model.scry_permissions.allowed_properties(@context).include?(property) }
        unless permitted
          return failure('Scry: computed predicate is not allowed for every expression property', category: :permission_denied, code: :predicate_denied, relation: @scope.none, path: field_path(:predicate))
        end
        args = prepare_predicate_arguments(predicate_obj, predicate_args(predicate_obj), array_aware: true)
        return failure_from_reported_error if args.equal?(PIPELINE_FAILED)
        prepared_args = prepare_registered_arguments(predicate_obj, args)
        return failure_from_reported_error if prepared_args.equal?(PIPELINE_FAILED)
        args = prepared_args || args
        nodes = args.each_with_index.map do |value, index|
          with_error_path(:args, index) { to_arel_node(value, attribute: expression) }
        end
        callback_args = predicate_obj[:custom_predicate] && !predicate_obj[:adapters] ? args : nodes
        node = build_predicate_node(predicate_obj, expression, callback_args)
        return failure_from_reported_error unless node

        result = @scope.where(node)
        success(apply_negation_if_needed(result))
      rescue Scry::ReportedError => error
        failure_from_reported_error(error)
      rescue Scry::FilterError => error
        raise if error.is_a?(Scry::ModelScopeError)

        failure(error.message)
      end

      private

      def property
        :computed
      end

      def expression_properties(node)
        if node.is_a?(Hash) && (node.key?(:property) || node.key?('property'))
          return [(node[:property] || node['property']).to_sym]
        end
        return [] unless node.is_a?(Hash)
        Array(node[:operands] || node['operands']).flat_map { |child| expression_properties(child) }
      end

    end
  end
end
