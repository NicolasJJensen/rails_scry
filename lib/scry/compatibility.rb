# frozen_string_literal: true

module Scry
  module Compatibility
    module_function

    def model_for(table)
      table = table.left if table.is_a?(Arel::Nodes::TableAlias)
      table = table.expr if table.is_a?(Arel::Nodes::Grouping)
      if table.is_a?(Arel::Nodes::SelectStatement)
        table = table.cores.first&.source&.left
      end
      model = table.respond_to?(:klass) ? table.klass : table.instance_variable_get(:@klass)
      return model if model

      if table.respond_to?(:froms)
        table.froms.each do |source|
          resolved = model_for(source)
          return resolved if resolved
        end
      end

      return unless table.respond_to?(:ast)

      source = table.ast.cores.first&.source&.left
      source && model_for(source)
    end

    def primary_key(model)
      key = model.primary_key
      unless key.is_a?(String) || key.is_a?(Symbol)
        raise FilterError, 'Scry: a scalar primary key is required at this call site'
      end
      key
    end

    def primary_keys(model)
      key = model.primary_key
      keys = key.is_a?(Array) ? key : [key]
      unless keys.all? { |item| item.is_a?(String) || item.is_a?(Symbol) } && !keys.empty?
        raise FilterError, 'Scry: model primary key must be a non-empty ordered key list'
      end
      keys.map(&:to_s).freeze
    end

    def key_attributes(model, relation: model.arel_table)
      primary_keys(model).map { |key| relation[key] }
    end

    def key_projection(relation, model = relation.klass)
      eager_loading = relation.eager_loading?
      if eager_loading
        relation = with_eager_loading(relation).except(:includes, :eager_load, :preload)
      end
      validate_grouped_primary_key!(relation, primary_keys(model))
      validate_derived_source!(relation)
      source_value = relation.from_clause.value
      if candidate_requires_wrapper?(relation)
        # Keep ordering and pagination inside the candidate query; projecting
        # distinct keys first changes the caller's selected page.
        keys = primary_keys(model)
        if relation.distinct_value && !source_value.is_a?(Arel::Nodes::TableAlias)
          validate_candidate_projection!(relation.arel, keys, single_column: false)
        end
        if source_value.is_a?(Arel::Nodes::TableAlias)
          if relation.group_values.any? && relation.select_values.empty?
            relation = relation.reselect(*keys.map { |key| source_value[key].as(key) })
          end
          source = relation.arel.as('scry_candidate')
        else
          unless relation.select_values.empty?
            selected = relation.select_values.flat_map { |node| candidate_projection_columns(node) }
            selected |= relation.arel.projections.flat_map { |node| candidate_projection_columns(node) }
            validate_candidate_projection_identity!(relation.arel, keys)
            exposes_keys = keys.all? { |key| selected.include?(key.to_s) || selected.include?('*') }
            unless exposes_keys
              if relation.distinct_value || relation.group_values.any?
                raise FilterError, 'Scry: candidate projection must expose all primary key columns under their original names'
              end
            end
          end
          fields = if relation.group_values.any? && relation.select_values.empty?
                      table = source_value.is_a?(Arel::Nodes::TableAlias) ? source_value : model.arel_table
                      keys.map { |key| table[key].as(key) }
                    elsif eager_loading ||
                      (relation.select_values.empty? && relation.distinct_value &&
                       (relation.joins_values.any? || relation.left_outer_joins_values.any?))
            keys.map { |key| model.arel_table[key].as(key) }
          elsif relation.select_values.empty?
            [Arel.star]
          elsif !keys.all? { |key| selected&.include?(key.to_s) || selected&.include?('*') }
            [*keys.map { |key| model.arel_table[key] }, *relation.select_values]
          else
            relation.select_values
          end
          inner = relation.reselect(*fields)
          source = inner.arel.as('scry_candidate')
        end
        projected = model.unscoped.from(source)
        projected = projected.select(*primary_keys(model).map { |key| source[key].as(key) })
        return projected
      end
      source = relation.from_clause.value
      table = source.is_a?(Arel::Nodes::TableAlias) ? source : model.arel_table
      relation.reselect(*primary_keys(model).map { |key| table[key].as(key) })
    end

    def candidate_requires_wrapper?(relation)
      relation.limit_value || relation.offset_value || relation.distinct_value ||
        relation.order_values.any? || relation.group_values.any? || !relation.select_values.empty?
    end

    def canonical_keys(model, values)
      keys = primary_keys(model)
      values = values.to_a if values.is_a?(Set)
      values = [values] unless values.is_a?(Array)
      tuples = if keys.length == 1
        values.map { |value| value.is_a?(Array) ? value : [value] }
      else
        values.map do |value|
          raise FilterError, 'Scry: composite key values must be ordered tuples' unless value.is_a?(Array)
          value
        end
      end
      tuples.map do |tuple|
          raise FilterError, keys.length == 1 ? 'Scry: association ID is invalid' : 'Scry: composite key tuple has the wrong arity' unless tuple.length == keys.length

        tuple.each_with_index.map do |value, index|
          type = model.type_for_attribute(keys[index])
          cast = type.cast(value)
          raise FilterError, keys.length == 1 ? 'Scry: association ID is invalid' : 'Scry: composite key value is invalid' if value.nil? || cast.nil?
          if type.type == :integer
            valid_integer = value.is_a?(Numeric) ? value == cast : value.to_s.match?(/\A[+-]?\d+\z/)
            raise FilterError, 'Scry: association ID is invalid' unless valid_integer
          end

          cast
        rescue ActiveModel::RangeError, ArgumentError, TypeError
          raise FilterError, keys.length == 1 ? 'Scry: association ID is invalid' : 'Scry: composite key value is invalid'
        end
      end.uniq.freeze
    end

    def key_membership(attributes, candidate, candidate_attributes: nil)
      attributes = Array(attributes)
      raise FilterError, 'Scry: key membership requires at least one attribute' if attributes.empty?
      candidate_attributes = Array(candidate_attributes || attributes)
      unless candidate_attributes.length == attributes.length
        raise FilterError, 'Scry: key membership attributes must have matching arity'
      end

      manager = candidate.respond_to?(:arel) ? candidate.arel : candidate
      if attributes.length == 1
        return attributes.first.in(manager) if candidate_attributes.first.name.to_s == attributes.first.name.to_s

        alias_node = manager.as('scry_keys')
        return attributes.first.in(Arel::SelectManager.new(alias_node).project(alias_node[candidate_attributes.first.name]).ast)
      end

      alias_node = manager.as('scry_keys')
      source = Arel::SelectManager.new(alias_node)
      candidate_attributes = candidate_attributes.map { |attribute| alias_node[attribute.name] }
      predicates = attributes.zip(candidate_attributes).map { |left, right| left.eq(right) }
      Arel::Nodes::Exists.new(source.project(Arel.sql('1')).where(predicates.reduce(&:and)).ast)
    end

    def group_by_keys(relation, model = relation.klass)
      relation.group(*key_attributes(model, relation: relation.klass.arel_table))
    end

    def property_type(model, name)
      column = if model.respond_to?(:columns_hash)
        model.columns_hash[name.to_s]
      else
        model.columns.find { |item| item.name.to_s == name.to_s }
      end
      return :string unless column
      return :array if column.respond_to?(:array) && column.array

      model.respond_to?(:type_for_attribute) ? model.type_for_attribute(name.to_s).type || column.type : column.type
    end

    def aggregate_operand_type(model, result_type, property = nil)
      return model.type_for_attribute(property.to_s) if result_type == :property

      type = result_type == :numerical ? :decimal : result_type
      ActiveRecord::Type.lookup(type, adapter: adapter(model))
    rescue ArgumentError
      nil
    end

    def cast_aggregate_operand(model, result_type, property, value)
      type = aggregate_operand_type(model, result_type, property)
      return value unless type
      return value.map { |item| cast_aggregate_operand(model, result_type, property, item) } if value.is_a?(Array)
      if value.is_a?(Range)
        first = cast_aggregate_operand(model, result_type, property, value.begin)
        last = cast_aggregate_operand(model, result_type, property, value.end)
        return ordered_range(first, last, value.exclude_end?)
      end
      return value if value.is_a?(Arel::Nodes::Node)

      enum = result_type == :property && model.defined_enums.key?(property.to_s)
      validate_aggregate_operand!(type, result_type, value) unless enum
      cast = type.serialize(value)
      if !value.nil? && cast.nil?
        raise FilterError, "Scry: invalid aggregate operand for #{result_type} result"
      end
      cast
    rescue ActiveModel::RangeError, ArgumentError, TypeError
      raise FilterError, "Scry: invalid aggregate operand for #{result_type} result"
    end

    def validate_aggregate_operand!(type, result_type, value)
      valid = case type.type
      when :integer
        value.is_a?(Numeric) ? value == type.cast(value) : value.to_s.match?(/\A[+-]?\d+\z/)
      when :decimal, :float
        value.is_a?(Numeric) || !BigDecimal(value.to_s, exception: false).nil?
      else
        true
      end
      return if valid || value.nil?

      raise FilterError, "Scry: invalid aggregate operand for #{result_type} result"
    end

    def ordered_range(first, last, exclude_end = false)
      if first && last && !first.is_a?(Arel::Nodes::Node) && !last.is_a?(Arel::Nodes::Node) && first > last
        first, last = last, first
      end
      Range.new(first, last, exclude_end)
    end

    def range_condition(attribute, lower, upper)
      if attribute.respond_to?(:relation) && attribute.relation.is_a?(Arel::Nodes::TableAlias) &&
          attribute.relation.left.is_a?(Arel::Nodes::Grouping)
        model = model_for(attribute.relation)
        type = model&.type_for_attribute(attribute.name.to_s)
        lower = type.serialize(lower) if type && !lower.nil?
        upper = type.serialize(upper) if type && !upper.nil?
      end
      conditions = []
      conditions << attribute.gteq(lower) unless lower.nil?
      conditions << attribute.lteq(upper) unless upper.nil?
      conditions.reduce(&:and) || truth(true)
    end

    def property_range(model, property, value)
      type = model.type_for_attribute(property.to_s)
      first = type.cast(value.begin)
      last = type.cast(value.end)
      if (!value.begin.nil? && first.nil?) || (!value.end.nil? && last.nil?)
        raise FilterError, 'Scry: invalid range operand'
      end
      ordered_range(first, last, value.exclude_end?)
    rescue ArgumentError, TypeError
      raise FilterError, 'Scry: invalid range operand'
    end

    def supported?(model, definition)
      adapters = definition[:adapters]
      !adapters || Array(adapters).map(&:to_s).include?(adapter(model))
    end

    def adapter(model)
      return nil unless model.respond_to?(:connection_pool)

      model.connection_pool.db_config.adapter.to_s.downcase
    end

    def database_key(model)
      return nil unless model.respond_to?(:connection_pool)

      pool = model.connection_pool
      schema = pool.with_connection do |connection|
        connection.schema_search_path if connection.respond_to?(:schema_search_path)
      end
      [pool.object_id, pool.db_config.database, schema, model.table_name, model.columns_hash.object_id, model.attribute_types.object_id]
    end

    def quoted(value, attribute)
      Arel::Nodes.build_quoted(value, attribute)
    end

    def serialize_property_value(model, property, value)
      return value if value.is_a?(Arel::Nodes::Node) || !model.respond_to?(:type_for_attribute)

      serialized = model.type_for_attribute(property.to_s).serialize(value)
      # Arel's generic quoted node cannot bind Hash/Array values. The adapter
      # type has already normalized scalar values; encode structured values so
      # PostgreSQL can infer the operand from the column/operator.
      serialized.is_a?(Hash) || serialized.is_a?(Array) ? JSON.generate(serialized) : serialized
    rescue ActiveModel::RangeError, ArgumentError, TypeError
      raise FilterError, 'Scry: invalid property operand'
    end

    def typed_property_arguments(attribute, args, collection: false)
      model = model_for(attribute.relation)
      return args unless model && model.column_names.include?(attribute.name.to_s)

      type = model.type_for_attribute(attribute.name.to_s)
      values = collection ? Array(args.first) : [args.first]
      prepared = values.map do |value|
        next value if value.is_a?(Arel::Nodes::Node) || value.is_a?(ActiveRecord::Relation) || value.is_a?(ActiveRecord::Base)

        node = Arel::Nodes.build_quoted(type.serialize(value))
        %i[json jsonb].include?(property_type(model, attribute.name)) ? cast(node, 'jsonb') : node
      end
      [collection ? prepared : prepared.first, *args.drop(1)]
    rescue ActiveModel::RangeError, ArgumentError, TypeError
      raise FilterError, 'Scry: invalid property operand'
    end

    def typed_range_arguments(attribute, args)
      model = model_for(attribute.relation)
      return args unless model && model.column_names.include?(attribute.name.to_s)

      type = model.type_for_attribute(attribute.name.to_s)
      values = args.map do |value|
        cast = type.cast(value)
        raise FilterError, 'Scry: invalid range operand' if !value.nil? && cast.nil?

        cast
      end
      values = ordered_range(*values).then { |range| [range.begin, range.end] } if values.length == 2
      values.map { |value| Arel::Nodes.build_quoted(type.serialize(value)) }
    rescue ActiveModel::RangeError, ArgumentError, TypeError
      raise FilterError, 'Scry: invalid range operand'
    end

    def cast(node, sql_type)
      Arel::Nodes::NamedFunction.new('CAST', [Arel::Nodes::As.new(node, Arel.sql(sql_type))])
    end

    def native_operand(model, property, predicate, value, attribute)
      type = model.type_for_attribute(property.to_s)
      if predicate.to_s.start_with?('range_') && !value.is_a?(Range) && !value.is_a?(Arel::Nodes::Node)
        raise FilterError, 'Scry: this range predicate requires a Range' unless predicate == :range_contains
        sql_type = {daterange: 'date', tsrange: 'timestamp', tstzrange: 'timestamptz', int4range: 'integer', int8range: 'bigint', numrange: 'numeric'}[type.type]
        raise FilterError, 'Scry: unsupported range subtype' unless sql_type && type.respond_to?(:subtype)
        return cast(Arel::Nodes.build_quoted(type.subtype.serialize(value)), sql_type)
      end
      node = quoted(serialize_property_value(model, property, value), nil)
      return cast(node, 'jsonb') if %i[json jsonb].include?(type_for(model, property).type)

      node
    end

    def type_for(model, property)
      model.type_for_attribute(property.to_s)
    end

    def truth(value)
      value ? Arel::Nodes::True.new : Arel::Nodes::False.new
    end

    def negate(node)
      return truth(false) if node.is_a?(Arel::Nodes::True)
      return truth(true) if node.is_a?(Arel::Nodes::False)

      Arel::Nodes::Not.new(Arel::Nodes::Grouping.new(node))
    end

    def condition(relation, outer_relation: nil)
      complex = relation.joins_values.any? || relation.left_outer_joins_values.any? ||
        relation.eager_loading? || relation.group_values.any? || !relation.having_clause.empty? ||
        relation.limit_value || relation.offset_value || !relation.from_clause.empty? || relation.with_values.any?
      return relation.where_clause.empty? ? truth(true) : relation.where_clause.ast unless complex

      # Extracting only WHERE would discard joins, grouping, pagination, and
      # other relation constraints, so preserve those through key membership.
      key_model = relation.klass
      source = (outer_relation || relation).from_clause.value
      key_relation = source.is_a?(Arel::Nodes::TableAlias) ? source : key_model.arel_table
      key_membership(
        key_attributes(key_model, relation: key_relation),
        key_projection(relation, key_model)
      )
    end

    def with_eager_loading(relation)
      relation.eager_loading? ? relation.send(:apply_join_dependency) : relation
    end

    def projection(relation, key)
      relation = with_eager_loading(relation)
      keys = primary_keys(relation.klass)
      unless keys.length == 1 && key.to_s == keys.first
        raise FilterError, 'Scry: projection key does not match the model primary key'
      end
      key_projection(relation, relation.klass)
    end

    def validate_projection_order!(relation)
      return unless relation.limit_value || relation.offset_value

      aliases = relation.select_values.flat_map do |selection|
        if selection.is_a?(Arel::Nodes::As)
          [qualified_identifier(selection.right.to_s).last]
        elsif selection.is_a?(String)
          selection.scan(/\bAS\s+("[^"]+"|`[^`]+`|\[[^\]]+\]|[a-zA-Z_]\w*)\s*(?=,|\z)/i)
            .flatten.map { |name| qualified_identifier(name).last }
        else
          []
        end
      end.compact
      relation.order_values.each do |ordering|
        ordering = ordering.expr while ordering.is_a?(Arel::Nodes::Ordering)
        next unless ordering.is_a?(String) || ordering.is_a?(Symbol)

        ordering.to_s.split(',').each do |item|
          identifier = item.strip.sub(/\s+NULLS\s+(FIRST|LAST)\z/i, '').sub(/\s+(ASC|DESC)\z/i, '')
          qualifier, name = qualified_identifier(identifier)
          next if qualifier || !name
          unknown_column = !relation.from_clause.value.is_a?(Arel::Nodes::TableAlias) &&
            !relation.klass.column_names.include?(name)
          next unless aliases.include?(name) || unknown_column

          raise FilterError, "Scry: ordering by #{name.inspect} depends on a selected alias that cannot be " \
            'preserved in a primary-key membership query with LIMIT/OFFSET. Order by the aggregate expression ' \
            'directly, or expose the ordering field through an Arel derived source.'
        end
      end
    end

    def validate_derived_source!(relation)
      source = relation.from_clause.value
      return unless source.is_a?(Arel::Nodes::TableAlias)

      keys = primary_keys(relation.klass)
      return if keys.all? { |key| derived_query_exposes_key?(source.left, key, relation.klass.table_name) }

      raise FilterError, 'Scry: derived source must expose all primary key columns under their original names'
    end

    def derived_query_exposes_key?(query, key, model_table, seen = Set.new)
      return false if seen.include?(query.object_id)

      seen.add(query.object_id)
      return query.name.to_s == model_table.to_s if query.is_a?(Arel::Table)

      statement = derived_select_statement(query)
      return false unless statement

      statement.cores.flat_map(&:projections).any? do |node|
        derived_projection_exposes_key?(node, query, key, model_table, seen)
      end
    ensure
      seen&.delete(query.object_id)
    end

    def derived_projection_exposes_key?(node, query, key, model_table, seen)
      if node.is_a?(Arel::Nodes::As)
        return false unless candidate_projection_columns(node).include?(key.to_s)

        return derived_projection_exposes_key?(node.left, query, key, model_table, seen)
      end
      if node.is_a?(Arel::Attributes::Attribute)
        return wildcard_exposes_key?(node, query, key, model_table, seen) if node.name.to_s == '*'
        return node.name.to_s == key.to_s && relation_exposes_key?(node.relation, query, key, model_table, seen)
      end
      if node.is_a?(String) || node.is_a?(Symbol)
        columns = candidate_projection_columns(node)
        return wildcard_exposes_key?(node, query, key, model_table, seen) if columns.include?('*')
        return columns.include?(key.to_s) && relation_exposes_key?(derived_query_source(query), query, key, model_table, seen)
      end

      false
    end

    def wildcard_exposes_key?(node, query, key, model_table, seen)
      relation = node.relation if node.is_a?(Arel::Attributes::Attribute) && node.name.to_s == '*'
      if relation.nil? && (node.is_a?(String) || node.is_a?(Symbol))
        text = node.to_s.strip
        match = text.match(/\A(?:"([^"]+)"|`([^`]+)`|\[([^\]]+)\]|([a-zA-Z_]\w*))\.\*\z/)
        qualifier = match&.captures&.compact&.first
        return false unless text == '*' || qualifier
        relation = derived_query_source(query) if text == '*'
        relation ||= qualifier
      end
      return false unless relation
      relation = resolve_query_relation(query, relation) if relation.is_a?(String)
      relation_exposes_key?(relation, query, key, model_table, seen)
    end

    def relation_exposes_key?(relation, query, key, model_table, seen)
      return false unless relation
      return derived_query_exposes_key?(relation.left, key, model_table, seen) if relation.is_a?(Arel::Nodes::TableAlias)

      name = relation.respond_to?(:name) ? relation.name : relation
      name.to_s == model_table.to_s
    end

    def resolve_query_relation(query, name)
      source = derived_query_source(query)
      return source if source.respond_to?(:name) && source.name.to_s == name.to_s

      nil
    end

    def derived_query_source(query)
      derived_select_statement(query)&.cores&.first&.source&.left
    end

    def derived_select_statement(query)
      query = query.ast if query.respond_to?(:ast)
      query = query.expr while query.is_a?(Arel::Nodes::Grouping)
      query if query.is_a?(Arel::Nodes::SelectStatement)
    end

    def validate_grouped_primary_key!(relation, key = primary_key(relation.klass))
      return if relation.group_values.empty?

      if key.is_a?(Array)
        keys = key.map(&:to_s)
        source = relation.from_clause.value
        source = relation.klass.arel_table unless source.is_a?(Arel::Nodes::TableAlias)
        return if keys.all? { |item| relation.group_values.any? { |node| grouped_primary_key?(node, item, source) } }

        raise FilterError, 'Scry: grouped relation must group by all primary key columns before projection'
      end

      source = relation.from_clause.value
      source = relation.klass.arel_table unless source.is_a?(Arel::Nodes::TableAlias)
      return if relation.group_values.any? { |node| grouped_primary_key?(node, key, source) }

      raise FilterError, 'Scry: grouped relation must group by its primary key before projection'
    end

    def validate_candidate_relation!(relation, key = primary_key(relation.klass))
      validate_grouped_primary_key!(relation, key)
      validate_derived_source!(relation)
    end

    def validate_candidate_query!(query, key, model_table)
      keys = Array(key).map(&:to_s)
      statement = derived_select_statement(query)
      groups = statement ? statement.cores.flat_map(&:groups) : []
      unless groups.empty?
        source = derived_query_source(query)
        unless keys.all? { |item| groups.any? { |node| grouped_primary_key?(node, item, source) } }
          raise FilterError, 'Scry: grouped relation must group by its primary key before projection'
        end
      end

      source = derived_query_source(query)
      return unless source.is_a?(Arel::Nodes::TableAlias)
      return if keys.all? { |item| derived_query_exposes_key?(source.left, item, model_table) }

      raise FilterError, 'Scry: derived source must expose its primary key under its original name'
    end

    def unwrap_grouping(node)
      node = node.expr while node.is_a?(Arel::Nodes::Grouping) || node.is_a?(Arel::Nodes::Group)
      node
    end

    def grouped_primary_key?(node, key, source)
      node = unwrap_grouping(node)
      if node.is_a?(Arel::Attributes::Attribute)
        return node.name.to_s == key.to_s && same_query_relation?(node.relation, source)
      end
      return false unless node.is_a?(String) || node.is_a?(Symbol)

      qualifier, column = qualified_identifier(node.to_s)
      return false unless column == key.to_s
      return true unless qualifier

      qualifier == query_relation_name(source)
    end

    def same_query_relation?(actual, expected)
      return false unless actual && expected

      actual.equal?(expected) || query_relation_name(actual) == query_relation_name(expected)
    end

    def query_relation_name(relation)
      return relation.right.to_s if relation.is_a?(Arel::Nodes::TableAlias)

      relation.respond_to?(:name) ? relation.name.to_s : nil
    end

    def qualified_identifier(value)
      identifier = '(?:"([^"]+)"|`([^`]+)`|\[([^\]]+)\]|([a-zA-Z_]\w*))'
      match = value.strip.match(/\A#{identifier}(?:\.#{identifier})?\z/)
      return [nil, nil] unless match

      parts = match.captures.each_slice(4).map { |captures| captures.compact.first }.compact
      parts.length == 2 ? parts : [nil, parts.first]
    end

    def validate_candidate_projection!(query, key, single_column: false)
      keys = Array(key).map(&:to_s)
      columns = query.projections.flat_map { |node| candidate_projection_columns(node) }
      valid = if single_column
        columns == keys
      else
        keys.all? { |item| columns.include?(item) } || columns.include?('*')
      end
      unless valid
        raise FilterError, 'Scry: candidate projection must expose its primary key under its original name. ' \
          'Use an explicit primary-key attribute. Raw Arel candidates must select only that key.'
      end
      validate_candidate_projection_identity!(query, keys)
    end

    # A projection named `id` is only a candidate identity when its Arel
    # attribute comes from the candidate query's source. A joined owner (or
    # any other table) can expose the same alias while carrying a different
    # identity. Keep raw SQL handling at the existing projection contract;
    # this check applies only to inspectable Arel attributes and aliases.
    def validate_candidate_projection_identity!(query, key)
      source = derived_query_source(query)
      return unless source

      Array(key).map(&:to_s).each do |name|
        nodes = query.projections.select { |node| candidate_projection_columns(node).include?(name) }
        next if nodes.empty? || nodes.any? { |node| candidate_projection_identity?(node, name, source) }

        raise FilterError, 'Scry: candidate projection primary key must come from the candidate relation'
      end
    end

    def candidate_projection_identity?(node, key, source)
      if node.is_a?(Arel::Nodes::As)
        return true unless candidate_projection_columns(node.right).include?(key.to_s)

        return candidate_projection_identity?(node.left, key, source)
      end
      if node.is_a?(String) || node.is_a?(Symbol)
        text = node.to_s.strip
        return true unless text.match?(/\s+AS\s+/i)

        text.split(',').each do |item|
          expression, alias_name = item.strip.split(/\s+AS\s+/i, 2)
          next unless alias_name && qualified_identifier(alias_name)&.last == key.to_s

          qualifier, column = qualified_identifier(expression)
          next unless qualifier && column == key.to_s

          return qualifier == query_relation_name(source)
        end
        return true
      end
      return true unless node.is_a?(Arel::Attributes::Attribute)
      return true unless node.name.to_s == key.to_s

      same_query_relation?(node.relation, source)
    end

    def candidate_projection_columns(node)
      case node
      when Arel::Attributes::Attribute
        [node.name.to_s]
      when Arel::Nodes::As
        candidate_projection_columns(node.right)
      when String, Symbol
        name = '[a-zA-Z_]\w*'
        identifier = "(?:#{name}|\"#{name}\"|`#{name}`|\\[#{name}\\])"
        node.to_s.split(',').map do |column|
          item = "(?:#{identifier}\\.)?(?:#{identifier}|\\*)(?:\\s+AS\\s+#{identifier})?"
          next nil unless column.match?(/\A\s*#{item}\s*\z/i)
          column.strip.split(/\s+AS\s+/i).last.split('.').last.delete('"`[]')
        end
      when Arel::Nodes::SqlLiteral
        candidate_projection_columns(node.to_s)
      else
        [nil]
      end
    end

    # Keep Rails' private association API in one version-tested boundary.
    def association_join(model, name)
      relation = model.unscoped
      dependency = relation.construct_join_dependency([name.to_sym], Arel::Nodes::InnerJoin)
      tracker = relation.send(:alias_tracker, [])
      joins = dependency.join_constraints([], tracker, [])
      target = dependency.send(:join_root).children.first.table
      [relation.joins(joins), target]
    end
  end
end
