# frozen_string_literal: true

module Scry
  module Filters
    class Property < Base
      def apply
        return failure_from_reported_error if depth_exceeded?
        return failure("Scry: property filter must be a Hash", code: :invalid_property_filter) unless @filter.is_a?(Hash)
        unless @filter[:property]
          return failure("Scry: filter has missing :property key", path: field_path(:property), code: :missing_property)
        end

        unless @filter[:predicate]
          return failure("Scry: filter has missing :predicate key", path: field_path(:predicate), code: :missing_predicate)
        end

        unless valid_property?
          return failure("Scry: invalid property: #{Input.identifier_label(@filter[:property])}", path: field_path(:property), category: :permission_denied, code: :property_denied, relation: @scope.none)
        end

        unless valid_predicate?
          return failure("Scry: invalid predicate: #{Input.identifier_label(@filter[:predicate])}, for the property: #{Input.identifier_label(@filter[:property])}", path: field_path(:predicate), category: :permission_denied, code: :predicate_denied, relation: @scope.none)
        end

        result = if custom_property?
          custom_filter = @model.custom_property_filters(@context)[property]
          unless custom_filter
            return failure("Scry: custom property filter #{property.inspect} returned nil", path: field_path(:property), code: :invalid_custom_property)
          end
          # Re-enter through the caller scope so custom expansion cannot widen
          # the relation that the host authorized.
          expanded = Filters::Group.new(
            model: @scope,
            filter: Input.normalize(custom_filter),
            context: @context,
            depth: @depth + 1
          ).with_path(@path || []).with_source(@source).apply
          return expanded if expanded.failed?
          relation = if predicate == :eq_false
            @scope.where(Compatibility.negate(Compatibility.condition(expanded.relation, outer_relation: @scope)))
          else
            expanded.relation
          end
          return Scry::Result.new(
            status: expanded.status,
            relation: apply_negation_if_needed(relation),
            diagnostics: expanded.diagnostics
          )
        else
          pred_obj = Scry.configuration.predicate_registry.by_name(predicate)
          return failure("Scry: unknown predicate #{predicate.inspect}", path: field_path(:predicate), code: :unknown_predicate) unless pred_obj

          run_predicate(predicate_args(pred_obj))
        end

        return failure_from_reported_error if result.nil?

        success(apply_negation_if_needed(result))
      rescue Scry::ReportedError => error
        failure_from_reported_error(error)
      rescue Scry::FilterError => e
        raise if e.is_a?(Scry::ModelScopeError)

        failure(e.message)
      end

      def custom_property?
        @model.custom_property_filters(@context).key?(property)
      end

      def property
        @_property ||= safe_to_sym(@filter[:property], field: :property)
      end

      def predicate
        @_predicate ||= safe_to_sym(@filter[:predicate], field: :predicate)
      end

    end
  end
end
