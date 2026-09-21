# frozen_string_literal: true

module Scry
  module Immutable
    module_function

    def copy(value)
      case value
      when ActiveSupport::HashWithIndifferentAccess
        value.each_with_object(value.class.new) do |(key, item), result|
          # HashWithIndifferentAccess assignment duplicates frozen arrays.
          Hash.instance_method(:[]=).bind_call(result, key, copy(item))
        end.freeze
      when Hash
        value.each_with_object({}) { |(key, item), result| result[copy(key)] = copy(item) }.freeze
      when Array
        value.map { |item| copy(item) }.freeze
      when Set
        value.map { |item| copy(item) }.to_set.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end
  end
end
