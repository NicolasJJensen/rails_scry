# frozen_string_literal: true

module Scry
  # Converts host-created Arel order trees onto the relation used by a query.
  # The caller supplies the relation identity map; no relation or SQL text is
  # inferred from client input.
  module OrderExpressionTranslator
    module_function

    def translate(node, relation_identity_map:)
      new(relation_identity_map:).translate(node)
    end

    # Internal visitor used to keep host relation identity at each attribute.
    class Translator
      NODE_HANDLERS = [
        [Arel::Attributes::Attribute, :translate_attribute],
        [Arel::Nodes::NamedFunction, :translate_function],
        [Arel::Nodes::Function, :translate_aggregate],
        [Arel::Nodes::InfixOperation, :translate_infix],
        [Arel::Nodes::Grouping, :translate_grouping],
        [Arel::Nodes::Ascending, :translate_ordering],
        [Arel::Nodes::Descending, :translate_ordering],
        [Arel::Nodes::NullsFirst, :translate_ordering],
        [Arel::Nodes::NullsLast, :translate_ordering],
        [Arel::Nodes::Quoted, :translate_quoted],
        [Arel::Nodes::Casted, :translate_casted],
        [Arel::Nodes::SqlLiteral, :translate_star]
      ].freeze

      def initialize(relation_identity_map:)
        @relation_identity_map = relation_identity_map || {}
      end

      def translate(node)
        handler = NODE_HANDLERS.find { |klass, _method| node.is_a?(klass) }&.last
        return send(handler, node) if handler

        unsupported(node)
      end

      private

      def translate_attribute(node)
        mapped = relation_mapping(node.relation)
        raise FilterError, "Scry: unmapped order expression attribute #{node.name.inspect}" unless mapped

        mapped[node.name]
      end

      def translate_function(node)
        translated = Arel::Nodes::NamedFunction.new(
          node.name,
          node.expressions.map { |expression| translate(expression) }
        )
        translated.distinct = node.distinct if node.respond_to?(:distinct) && translated.respond_to?(:distinct=)
        translated
      end

      def translate_infix(node)
        Arel::Nodes::InfixOperation.new(node.operator, translate(node.left), translate(node.right))
      end

      def translate_grouping(node)
        Arel::Nodes::Grouping.new(translate(node.expr))
      end

      def translate_ordering(node)
        node.class.new(translate(node.expr))
      end

      def translate_casted(node)
        Arel::Nodes::Casted.new(node.value, translate(node.attribute))
      end

      def translate_quoted(node)
        Arel::Nodes::Quoted.new(node.expr)
      end

      def translate_aggregate(node)
        translated = node.class.new(node.expressions.map { |expression| translate(expression) })
        translated.distinct = node.distinct if node.respond_to?(:distinct) && translated.respond_to?(:distinct=)
        translated
      end

      def relation_mapping(relation)
        entry = @relation_identity_map.each_pair.find { |key, _value| key.equal?(relation) }&.last
        return unless entry

        return entry unless entry.is_a?(Hash)

        entry.values_at(:relation, "relation", :table, "table").compact.first
      end

      def translate_star(node)
        return node if node.to_s == "*"

        unsupported(node)
      end

      def unsupported(node)
        raise FilterError, "Scry: unsupported order expression node #{node.class}"
      end
    end

    private_constant :Translator

    def new(relation_identity_map:)
      Translator.new(relation_identity_map:)
    end
    private_class_method :new
  end
end
