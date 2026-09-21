# frozen_string_literal: true

module Scry
  module Input
    module_function

    def identifier_label(value)
      return "<#{value.class}>" unless value.is_a?(String) || value.is_a?(Symbol)

      text = value.to_s
      label = text.byteslice(0, 80).scrub.inspect
      text.bytesize > 80 ? "#{label} (#{text.bytesize} bytes)" : label
    end

    def normalize(filter)
      configuration = Scry.configuration
      stack = [[filter, 0, false]]
      ancestors = Set.new
      nodes = bytes = 0
      until stack.empty?
        value, depth, leaving = stack.pop
        if leaving
          ancestors.delete(value.object_id)
          next
        end
        nodes += 1
        raise FilterError, 'Scry: filter exceeds max_filter_nodes' if nodes > configuration.max_filter_nodes
        bytes += value.bytesize if value.is_a?(String)
        raise FilterError, 'Scry: filter exceeds max_filter_bytes' if bytes > configuration.max_filter_bytes
        next unless value.is_a?(Hash) || value.is_a?(Array)
        raise FilterError, 'Scry: cyclic filter payload' if ancestors.include?(value.object_id)
        # Normalization runs before filter classes enforce group depth, so it
        # separately caps arbitrary container nesting.
        raise FilterError, 'Scry: filter payload is nested too deeply' if depth > configuration.max_filter_depth * 4 + 16
        child_count = value.is_a?(Hash) ? value.size * 2 : value.size
        raise FilterError, 'Scry: filter exceeds max_filter_nodes' if nodes + child_count > configuration.max_filter_nodes
        ancestors.add(value.object_id)
        stack << [value, depth, true]
        items = value.is_a?(Hash) ? value.to_a.flatten(1) : value
        items.reverse_each { |item| stack << [item, depth + 1, false] }
      end
      normalize_filter(filter)
    end

    # Only DSL keys are normalized; JSON values belong to the column's serializer.
    def normalize_filter(filter)
      return filter unless filter.is_a?(Hash)
      filter.each_with_object({}) do |(key, value), result|
        key = key.to_sym if key.is_a?(String)
        value = normalize_filter(value) if %i[scoping order expression operands].include?(key)
        value = value.map { |item| normalize_filter(item) } if key == :order && value.is_a?(Array)
        value = value.map { |item| normalize_filter(item) } if key == :operands && value.is_a?(Array)
        if key == :filters && (filter[:type] || filter['type'] || 'group').to_s == 'group' && value.is_a?(Array)
          value = value.map { |child| normalize_filter(child) }
        end
        result[key] = value
      end
    end
  end
end
