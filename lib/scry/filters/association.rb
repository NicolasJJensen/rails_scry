# frozen_string_literal: true

module Scry
  module Filters
    class Association < Base
      def property
        @_property ||= safe_to_sym(@filter[:association], field: :association)
      end

      def apply
        return failure_from_reported_error if depth_exceeded?
        return failure('Scry: association filter must be a Hash', code: :invalid_association_filter) unless @filter.is_a?(Hash)
        return failure('Scry: association requires an association', path: field_path(:association), code: :missing_association) unless @filter[:association]
        return failure('Scry: association requires a predicate', path: field_path(:predicate), code: :missing_predicate) unless @filter[:predicate]
        name = property
        return failure_from_reported_error unless name
        return failure('Scry: invalid or missing association', path: field_path(:association), code: :unknown_association) unless @model.reflect_on_association(name)
        return failure('Scry: disallowed association', path: field_path(:association), category: :permission_denied, code: :association_denied, relation: @scope.none) unless valid_association?
        if %i[eq not_eq].include?(predicate)
          return failure("Scry: association predicate #{predicate} is unsupported; use an association membership predicate", path: field_path(:predicate), code: :unsupported_predicate)
        end
        return failure('Scry: disallowed association predicate', path: field_path(:predicate), category: :permission_denied, code: :association_denied, relation: @scope.none) unless valid_predicate?

        reflection = @model.reflect_on_association(property)
        if reflection.respond_to?(:polymorphic?) && reflection.polymorphic?
          with_error_path(:target_type) do
            targets = @model.scry_permissions.allowed_association_targets(property, @context)
            target_type = @filter[:target_type]
            unless target_type && targets.key?(target_type.to_s)
              raise Scry::FilterError, 'Scry: polymorphic association requires an allowed target_type'
            end
          end
        end
        query = with_error_path(:association) do
          AssociationQuery.new(@model, property, context: @context, target_type: @filter[:target_type])
        end
        return failure("Scry: model #{query.child_model.name} not allowed", category: :permission_denied, code: :association_denied, relation: @scope.none) unless validate_model_filterable(query.child_model)
        definition = Scry.configuration.predicate_registry.by_name(predicate)
        return failure('Scry: unknown association predicate', path: field_path(:predicate), code: :unknown_predicate) unless definition
        scoping = nil
        scoping_diagnostics = []
        unless @filter[:scoping].nil?
          return failure('Scry: association scoping must be a Hash', path: field_path(:scoping), code: :invalid_scoping) unless @filter[:scoping].is_a?(Hash)
          scoping = Group.new(model: query.child_model, filter: @filter[:scoping], context: @context, depth: @depth + 1)
            .with_path([*(@path || []), :scoping]).apply
          if scoping.failed?
            return Scry::Result.new(status: :failed, relation: @scope, diagnostics: scoping.diagnostics)
          end
          scoping_diagnostics = scoping.diagnostics if scoping.partial?
          scoping = scoping.relation
        end
        args = !@filter.key?(:args) && scoping ? [] : predicate_args(definition)
        transforms = applicable_property_transforms(property, [predicate, *Array(definition[:types])])
        args = prepare_predicate_arguments(definition, args, transforms: transforms, validate_shape: false)
        return failure_from_reported_error if args.equal?(PIPELINE_FAILED)
        prepared_args = prepare_registered_arguments(definition, args)
        return failure_from_reported_error if prepared_args.equal?(PIPELINE_FAILED)
        args = prepared_args if prepared_args
        attribute = query.prepared_attribute(
          apply_attribute_transforms(source_attribute(property), transforms[:attribute]),
          owner_relation: source_relation,
          scoping:
        )
        node = build_predicate_node(definition, attribute, args)
        return failure_from_reported_error unless node
        relation = apply_negation_if_needed(source_relation.where(node))
        scoping_diagnostics.empty? ? success(relation) : partial(relation, scoping_diagnostics)
      rescue Scry::ReportedError => error
        failure_from_reported_error(error)
      rescue Scry::FilterError => e
        raise if e.is_a?(Scry::ModelScopeError)

        failure(e.message)
      end

    end
  end
end
