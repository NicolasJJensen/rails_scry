# frozen_string_literal: true

module Scry
  # Reduces a set of permissions against an initial collection using
  # whitelist/blacklist/includelist/excludelist semantics.
  #
  # This extracts the repeated pattern found in FilterPermissions where
  # each permission is applied as a set operation on an accumulator.
  module PermissionResolver
    module_function

    # Reduces permissions over an initial array/set.
    #
    # @param initial [Array] the starting set of allowed items
    # @param permissions [Enumerable] permissions to apply (each must have :list_type and :block)
    # @param context [Object] passed to each permission block
    # @param universe [Array, nil] the full set of valid items (used by :includelist to constrain additions)
    # @param model [Class, nil] the owning model for redacted diagnostics
    # @return [Array] the reduced set after all permissions are applied
    def reduce(initial, permissions:, context:, universe: nil, model: nil)
      universe ||= initial
      permissions.reduce(initial) do |acc, permission|
        items = Scry.invoke_callback(
          label: "#{permission[:list_type]} permission",
          model:, context:, path: []
        ) { permission[:block].call(context) }
        unless items.is_a?(Array) || items.is_a?(Set)
          raise Scry::FilterError, 'Scry: permission must return an Array or Set of names'
        end
        items = items.map do |item|
          unless item.is_a?(String) || item.is_a?(Symbol)
            raise Scry::FilterError, 'Scry: permission entries must be names'
          end
          item.to_sym
        end
        case permission[:list_type]
        when :whitelist
          acc & items
        when :blacklist
          acc - items
        when :includelist
          acc | (items & universe)
        when :excludelist
          acc - items
        else
          raise Scry::FilterError,
            "Scry: unrecognized list_type #{permission[:list_type].inspect}"
        end
      end
    end
  end
end
