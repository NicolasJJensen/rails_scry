# frozen_string_literal: true

module Scry
  module Filters
    class Group < Base
      def apply
        return failure_from_reported_error if depth_exceeded?
        return failure('Scry: group filter must be a Hash', code: :invalid_group) unless @filter.is_a?(Hash)
        return failure('Scry: group filter has missing :predicate key', code: :missing_predicate) unless @filter[:predicate]
        return failure('Scry: group filter has missing or non-array :filters key', code: :invalid_group_filters) unless @filter[:filters].is_a?(Array)

        operator = @filter[:predicate].to_s.downcase.to_sym
        return failure('Scry: invalid group predicate', code: :invalid_group_predicate) unless %i[and or].include?(operator)

        nested_results = []
        nodes = @filter[:filters].each_with_index.filter_map do |child, index|
          nested_path = [*diagnostic_path, :filters, index]
          result = compile_nested_filter(child, path: nested_path)
          if result.failed?
            nested_results << result
            next
          end
          begin
            condition = if @source
              Compatibility.key_membership(
                Compatibility.key_attributes(@model, relation: @source),
                Compatibility.key_projection(result.relation, @model)
              )
            else
              Compatibility.condition(result.relation, outer_relation: @scope)
            end
            nested_results << result
            condition
          rescue FilterError => error
            nested_results << failure(error.message, path: nested_path)
            nil
          end
        end

        node = nodes.reduce { |left, right| operator == :and ? left.and(right) : left.or(right) }
        node ||= Compatibility.truth(operator == :and)
        node = Compatibility.negate(node) if BOOLEAN_TYPE.cast(@filter[:negate])
        result_scope = source_relation
        if @selection_base_relation
          result_scope = result_scope.where(
            Compatibility.key_membership(
              Compatibility.key_attributes(
                @model,
                relation: @source || @model.arel_table
              ),
              Compatibility.key_projection(@selection_base_relation, @model)
            )
          )
        end
        result = apply_selection_modifiers(result_scope.where(node))
        return failure_from_reported_error(relation: result_scope) unless result

        diagnostics = nested_results.flat_map(&:diagnostics)
        failed_children = nested_results.any?(&:failed?)
        partial_children = nested_results.any?(&:partial?)
        return success(result) unless failed_children || partial_children

        valid_children = nested_results.any? { |nested_result| !nested_result.failed? }
        valid_children ? partial(result, diagnostics) : Scry::Result.new(status: :failed, relation: result, diagnostics:)
      rescue Scry::ReportedError => error
        failure_from_reported_error(error)
      end

      def with_selection_base_relation(selection_base_relation)
        @selection_base_relation = selection_base_relation
        self
      end

      private

      def apply_selection_modifiers(relation)
        order = @filter[:order]
        if order
          unless order.is_a?(Array)
            return handle_error('Scry: group order must be an Array')
          end
          order_nodes = order.map do |item|
            unless item.is_a?(Hash)
              raise Scry::FilterError, 'Scry: group order entries must be Hashes'
            end
            direction = item[:direction].to_s.downcase
            raise Scry::FilterError, 'Scry: group order direction must be asc or desc' unless %w[asc desc].include?(direction)
            expression = item[:expression] || (item[:property] && {property: item[:property]})
            raise Scry::FilterError, 'Scry: group order requires property or expression' unless expression
            order_properties = @model.scry_permissions.allowed_order_properties(@context)
            expression_properties(expression).each do |property|
              unless order_properties.include?(property.to_sym)
                raise Scry::FilterError, "Scry: invalid order property #{Input.identifier_label(property)}"
              end
            end
            node = Expression.compile(
              @model, expression,
              allowed_properties: @model.scry_permissions.allowed_properties(@context),
              source: @source
            )
            direction == 'asc' ? node.asc : node.desc
          end
          relation = relation.reorder(*order_nodes)
        end
        %i[limit offset].each do |modifier|
          value = @filter[modifier]
          next if value.nil?
          unless value.is_a?(Integer) && value >= 0
            raise Scry::FilterError, "Scry: group #{modifier} must be a non-negative Integer"
          end
          relation = relation.public_send(modifier, value)
        end
        relation
      rescue Scry::FilterError => error
        handle_error(error.message)
      end

      def expression_properties(node)
        return [] unless node.is_a?(Hash)
        property = node[:property] || node['property']
        return [property.to_sym] if property

        Array(node[:operands] || node['operands']).flat_map { |child| expression_properties(child) }
      end

    end
  end
end
