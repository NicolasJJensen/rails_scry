# frozen_string_literal: true

module Scry
  module Predications
    module AssociationAttributeBehavior
      attr_accessor :scry_association_query

      %i[has_any not_has_any has_all not_has_all only_has_any only_has_all].each do |predicate_name|
        define_method(predicate_name) do |*values|
          query = AssociationQuery.for_attribute(self)
          value = values.empty? ? query.eligible_child_relation : values.first
          query.public_send(predicate_name, value)
        end
      end

    end

    module Association
      include AssociationAttributeBehavior

    end
  end
end
