# frozen_string_literal: true

module Scry
  # Intersects host authorization relations with every model query by primary key.
  module ModelScope
    module_function

    def apply(relation, context: nil)
      validate_relation!(relation)
      restrict(relation, model: relation.klass, table: relation_table(relation), context:)
    end

    def apply_to_table(relation, model:, table:, context: nil)
      validate_relation!(relation)
      restrict(relation, model:, table:, context:)
    end

    def registered?(model)
      model.respond_to?(:scry_scopes) && model.scry_scopes.any?
    end

    def restrict(relation, model:, table:, context:)
      return relation unless registered?(model)

      model.scry_scopes.reduce(relation) do |current, callback|
        # Key intersection avoids merging a policy relation in ways that would
        # replace the caller's aliases, joins, or pagination.
        authorized = resolve(model, callback, context)
        attributes = Compatibility.key_attributes(model, relation: table)
        keys = Compatibility.key_projection(authorized, model)
        current.where(Compatibility.key_membership(attributes, keys))
      end
    end
    private_class_method :restrict

    def resolve(model, callback, context)
      relation = call(model, callback, context)
      validate_scope_relation!(relation, model)

      Compatibility.primary_keys(model)
      Compatibility.validate_derived_source!(relation)
      relation
    rescue ModelScopeError
      raise
    rescue StandardError => e
      raise ModelScopeError, "Scry: model scope callback failed for #{model.name} (#{e.class})"
    end
    private_class_method :resolve

    def call(model, callback, context)
      return model.instance_exec(context, &callback) if callback.is_a?(Proc)

      callback.call(context)
    end
    private_class_method :call

    def validate_scope_relation!(relation, model)
      return if relation.is_a?(ActiveRecord::Relation) && relation.klass.base_class == model.base_class

      raise ModelScopeError, "Scry: model scope must return an ActiveRecord relation for #{model.name}"
    end
    private_class_method :validate_scope_relation!

    def validate_relation!(relation)
      return if relation.is_a?(ActiveRecord::Relation)

      raise ModelScopeError, "Scry: model scope requires an ActiveRecord relation"
    end
    private_class_method :validate_relation!

    def relation_table(relation)
      source = relation.from_clause.value
      source.is_a?(Arel::Nodes::TableAlias) ? source : relation.klass.arel_table
    end
    private_class_method :relation_table
  end
end
