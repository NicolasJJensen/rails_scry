# frozen_string_literal: true

module Scry
  # Reduces a set of permissions over a hash accumulator (as opposed to PermissionResolver
  # which operates on arrays/sets). Used for hash-based permissions like custom_property_filters
  # and aggregates.
  #
  # The caller provides a block that receives (acc, map, list_type) and must return the
  # updated accumulator for each permission.
  module HashPermissionResolver
    module_function

    # @param initial [Hash] the starting hash
    # @param permissions [Enumerable] permissions to apply (each must have :list_type and :block)
    # @param context [Object] passed to each permission block
    # @param model [Class, nil] the owning model for redacted diagnostics
    # @yield [acc, map, list_type] called for each permission to merge/filter the accumulator
    # @return [Hash] the reduced hash after all permissions are applied
    def reduce(initial, permissions:, context:, model: nil)
      permissions.reduce(initial) do |acc, permission|
        map = Scry.invoke_callback(
          label: "#{permission[:list_type]} permission",
          model:, context:, path: []
        ) { permission[:block].call(context) } || {}
        unless map.is_a?(Hash)
          raise Scry::FilterError, 'Scry: permission must return a Hash'
        end
        yield(acc, map, permission[:list_type])
      end
    end
  end
end
