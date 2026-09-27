# frozen_string_literal: true

module Scry
  module Filters
    class Group < Base
      def apply
        return failure_from_reported_error if depth_exceeded?
        return failure('Scry: group filter must be a Hash', code: :invalid_group) unless @filter.is_a?(Hash)
        return failure('Scry: group filter has missing :predicate key', code: :missing_predicate, path: field_path(:predicate)) unless @filter[:predicate]
        return failure('Scry: group filter has missing or non-array :filters key', code: :invalid_group_filters, path: field_path(:filters)) unless @filter[:filters].is_a?(Array)

        operator = @filter[:predicate].to_s.downcase.to_sym
        return failure('Scry: invalid group predicate', code: :invalid_group_predicate, path: field_path(:predicate)) unless %i[and or].include?(operator)

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
          rescue Scry::ReportedError => error
            nested_results << failure_from_reported_error(error, relation: @scope)
            nil
          rescue FilterError => error
            raise if error.is_a?(Scry::ModelScopeError)

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
        diagnostics = Array(nested_results).flat_map(&:diagnostics)
        Scry::Result.new(status: :failed, relation: @scope, diagnostics: [*diagnostics, error.diagnostic])
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
            return handle_error('Scry: group order must be an Array', path: field_path(:order))
          end
          order_nodes = order.each_with_index.map do |item, index|
            item_path = field_path(:order, index)
            unless item.is_a?(Hash)
              handle_error('Scry: group order entries must be Hashes', path: item_path)
            end
            direction = item[:direction].to_s.downcase
            unless %w[asc desc].include?(direction)
              handle_error('Scry: group order direction must be asc or desc', path: [*item_path, :direction])
            end
            expression = item[:expression] || (item[:property] && {property: item[:property]})
            unless expression
              handle_error('Scry: group order requires property or expression', path: [*item_path, :expression])
            end
            order_properties = @model.scry_permissions.allowed_order_properties(@context)
            expression_property_paths(expression, [*item_path, *(item[:expression] ? [:expression] : [])]).each do |property, property_path|
              unless order_properties.include?(property.to_s.to_sym)
                handle_error("Scry: invalid order property #{Input.identifier_label(property)}", path: property_path)
              end
            end
            node = Expression.compile(
              @model, expression,
              allowed_properties: @model.scry_permissions.allowed_properties(@context),
              source: @source,
              path: [*item_path, *(item[:expression] ? [:expression] : [])]
            )
            direction == 'asc' ? node.asc : node.desc
          end
          relation = relation.reorder(*order_nodes)
        end
        %i[limit offset].each do |modifier|
          value = @filter[modifier]
          next if value.nil?
          unless value.is_a?(Integer) && value >= 0
            handle_error("Scry: group #{modifier} must be a non-negative Integer", path: field_path(modifier))
          end
          relation = relation.public_send(modifier, value)
        end
        relation
      rescue Scry::ReportedError
        raise
      rescue Scry::FilterError => error
        handle_error(error.message)
      end

      def expression_property_paths(node, path)
        return [] unless node.is_a?(Hash)
        property = node[:property] || node['property']
        return [[property, [*path, :property]]] if property

        operands = node[:operands] || node['operands']
        return [] unless operands.is_a?(Array)

        operands.each_with_index.flat_map do |child, index|
          expression_property_paths(child, [*path, :operands, index])
        end
      end

    end
  end
end
