# frozen_string_literal: true

module Scry
  module Expression
    OPERATORS = {
      'add' => '+',
      'subtract' => '-',
      'multiply' => '*',
      'divide' => '/'
    }.freeze

    module_function

    def compile(model, expression, allowed_properties:, source: nil)
      unless expression.is_a?(Hash)
        raise Scry::InvalidOperandError, 'Scry: expression must be a Hash'
      end
      if expression.key?(:property) || expression.key?('property')
        property = (expression[:property] || expression['property']).to_s
        unless allowed_properties.include?(property.to_sym)
          raise Scry::FilterError, "Scry: invalid property: #{Input.identifier_label(property)}"
        end
        return (source || model.arel_table)[property]
      end
      if expression.key?(:literal) || expression.key?('literal')
        value = expression[:literal] || expression['literal']
        unless value.is_a?(Numeric) && value.finite?
          raise Scry::InvalidOperandError, 'Scry: numeric expression literals must be finite'
        end
        return Arel::Nodes.build_quoted(value)
      end

      operator = (expression[:operator] || expression['operator']).to_s
      symbol = OPERATORS[operator]
      raise Scry::InvalidOperandError, "Scry: invalid expression operator #{operator.inspect}" unless symbol
      operands = expression[:operands] || expression['operands']
      unless operands.is_a?(Array) && operands.length == 2
        raise Scry::InvalidOperandError, "Scry: #{operator} requires exactly two operands"
      end
      left = compile(model, operands[0], allowed_properties:, source:)
      right = compile(model, operands[1], allowed_properties:, source:)
      left = Arel::Nodes::Grouping.new(left) if expression_node?(operands[0])
      right = Arel::Nodes::Grouping.new(right) if expression_node?(operands[1])
      if operator == 'divide' && literal_zero?(operands[1])
        raise Scry::InvalidOperandError, 'Scry: division by zero is not allowed'
      end
      if operator == 'divide'
        right = Arel::Nodes::NamedFunction.new('NULLIF', [right, Arel::Nodes.build_quoted(0)])
        adapter = Compatibility.adapter(model)
        # SQLite truncates integer division; normalize both supported adapters
        # to a fractional result before applying the caller's comparison.
        sql_type = adapter == 'sqlite3' ? 'REAL' : 'DECIMAL' if adapter == 'sqlite3' || adapter == 'postgresql'
        left = Compatibility.cast(left, sql_type) if sql_type
      end
      Arel::Nodes::InfixOperation.new(symbol, left, right)
    end

    def result_type(model, expression)
      return Compatibility.property_type(model, expression[:property] || expression['property']) if expression.key?(:property) || expression.key?('property')
      return :numerical if expression.key?(:literal) || expression.key?('literal')

      operator = (expression[:operator] || expression['operator']).to_s
      return :numerical if OPERATORS.key?(operator)

      raise Scry::InvalidOperandError, 'Scry: invalid expression operator'
    end

    def literal_zero?(node)
      value = node[:literal] || node['literal'] if node.is_a?(Hash)
      value == 0
    end

    def expression_node?(node)
      node.is_a?(Hash) && (node.key?(:operator) || node.key?('operator'))
    end
  end
end
