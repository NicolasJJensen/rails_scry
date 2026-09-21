# frozen_string_literal: true

module Scry
  class AssociationQuery
    attr_reader :model, :reflection, :child_model, :joined_relation, :child_table

    # A candidate set has one canonical key projection. Membership and
    # cardinality must use that same projection so duplicate raw rows cannot
    # make has_all require more records than matching can select.
    class CandidateKeySet
      def initialize(query, value)
        @query = query
        @value = value
      end

      def projection
        @projection ||= @query.send(:candidate_projection, @value)
      end

      def count
        return Arel::Nodes.build_quoted(projection.length) if projection.is_a?(Array)

        table = projection.as('scry_candidates')
        keys = Compatibility.primary_keys(@query.child_model)
        aggregate = keys.length == 1 ? table[keys.first].count(true) : Arel::Nodes::NamedFunction.new('COUNT', [Arel.star])
        Arel::SelectManager.new(table).project(aggregate)
      end
    end

    def self.for_attribute(attribute)
      if attribute.respond_to?(:scry_association_query)
        query = attribute.scry_association_query
        return query if query
      end

      model = Compatibility.model_for(attribute.relation)
      raise FilterError, 'Scry: association attributes must belong to a model table' unless model

      new(model, attribute.name)
    end

    def initialize(model, name, context: nil, target_type: nil)
      @model = model
      @context = context
      @reflection = model.reflect_on_association(name.to_s)
      raise FilterError, 'Scry: invalid or missing association' unless @reflection

      @child_model = if @reflection.respond_to?(:polymorphic?) && @reflection.polymorphic?
        targets = model.scry_permissions.allowed_association_targets(name, context)
        target = targets[target_type.to_s] if target_type
        raise FilterError, 'Scry: polymorphic association requires an allowed target_type' unless target
        target
      else
        begin
          @reflection.klass
        rescue NameError
          raise FilterError, 'Scry: association model not found'
        end
      end
      unless child_model.respond_to?(:scry_permissions)
        raise FilterError, 'Scry: association model does not include Filterable'
      end
      Compatibility.primary_keys(model)
      Compatibility.primary_keys(child_model)
      begin
        if @reflection.respond_to?(:polymorphic?) && @reflection.polymorphic?
          @joined_relation, @child_table = polymorphic_join(target_type)
        else
          @joined_relation, @child_table = Compatibility.association_join(model, name)
        end
      rescue NameError
        raise FilterError, 'Scry: association model not found'
      rescue ArgumentError
        # Owner-dependent callbacks run with a concrete owner; their arbitrary
        # Ruby behavior cannot be translated generically into one set-based query.
        raise FilterError, 'Scry: association scope cannot be joined; instance-dependent scopes are not supported'
      end
      @association_scope = if (scope = @reflection.scope)
        raise ArgumentError if scope.arity.positive?

        child_model.instance_exec(&scope)
      else
        child_model.all
      end
      scoped_scope = @association_scope.except(:limit, :offset, :order, :joins, :left_outer_joins)
      @scoped_relation = joined_relation.merge(scoped_scope)
      scoped_joins = @association_scope.arel.join_sources
      existing_join_names = joined_relation.arel.join_sources.filter_map do |join|
        source = join.respond_to?(:left) ? join.left : nil
        if source.is_a?(Arel::Nodes::TableAlias)
          [source.left.name.to_s, source.name.to_s]
        elsif source.respond_to?(:name)
          [source.name.to_s, nil]
        end
      end.to_set
      missing_joins = scoped_joins.reject do |join|
        source = join.respond_to?(:left) ? join.left : nil
        identity = if source.is_a?(Arel::Nodes::TableAlias)
          [source.left.name.to_s, source.name.to_s]
        elsif source.respond_to?(:name)
          [source.name.to_s, nil]
        end
        identity && existing_join_names.include?(identity)
      end
      @scoped_relation = @scoped_relation.joins(*missing_joins) unless missing_joins.empty?
      @scoped_relation = apply_model_scopes(@scoped_relation)
    end

    def prepared_attribute(attribute, owner_relation:, scoping: nil)
      prepared_query = prepared(owner_relation:, scoping:)
      attribute.dup.tap do |prepared_attribute|
        prepared_attribute.extend(Predications::AssociationAttributeBehavior)
        prepared_attribute.scry_association_query = prepared_query
      end
    end

    def prepared(owner_relation:, scoping: nil)
      query = dup
      query.instance_variable_set(:@owner_relation, owner_relation)
      query.instance_variable_set(:@predicate_scoping, scoping)
      query
    end

    def eligible_child_relation
      scope = @association_scope.except(:limit, :offset, :order)
      scope = scope.merge(@predicate_scoping) if @predicate_scoping
      apply_model_scopes(scope)
    end

    def parent_keys
      Compatibility.key_attributes(model)
    end

    def parent_keys_for(scope = joined_relation)
      source = scope.from_clause.value
      if source.is_a?(Arel::Nodes::TableAlias)
        Compatibility.primary_keys(model).map { |key| source[key] }
      else
        parent_keys
      end
    end

    def selected_child_name(name)
      "scry_child_#{name}"
    end

    def child_keys
      Compatibility.key_attributes(child_model, relation: child_table)
    end

    def child_keys_for(scope = joined_relation)
      source = scope.from_clause.value
      if source.is_a?(Arel::Nodes::TableAlias)
        Compatibility.primary_keys(child_model).map { |key| source[selected_child_name(key)] }
      else
        child_keys
      end
    end

    # A per-owner window preserves association limit/offset semantics; applying
    # them to the joined relation would let early owners consume the whole page.
    def selected_relation(fields: [])
      implicit_one = @reflection.macro == :has_one
      scoped = @scoped_relation
      scoped = scoped.group(*parent_keys) if @association_scope.group_values.any?
      return scoped unless implicit_one || @association_scope.limit_value || @association_scope.offset_value

      order_nodes = @association_scope.order_values.map do |order|
        expression = order.respond_to?(:expr) ? order.expr : order
        [expression, order.respond_to?(:direction) ? order.direction : :asc]
      end

      fields = Array(fields).map(&:to_s).uniq - child_keys.map { |attribute| attribute.name.to_s }
      fields = (fields | child_order_fields(order_nodes)) - child_keys.map { |attribute| attribute.name.to_s }
      order_field_attributes = order_nodes.flat_map { |expression, _direction| order_projection_attributes(expression) }
        .each_with_object({}) { |attribute, map| map[attribute.name.to_s] ||= attribute }
      ranking_parent_keys = parent_keys
      ranking_child_keys = child_keys
      ranking_fields = fields.map { |field| order_field_attributes[field] || child_table[field] }
      output_parent_names = parent_keys.map(&:name)
      ranking_source = scoped
      order_identity_map = { child_model.arel_table => child_table, @association_scope.arel_table => child_table }
      @association_scope.arel.join_sources.each do |join|
        source = join.respond_to?(:left) ? join.left : nil
        order_identity_map[source] = source if source.respond_to?(:name)
      end
      order_nodes.flat_map { |expression, _direction| order_attributes(expression) }
        .each { |attribute| order_identity_map[attribute.relation] ||= child_table }

      if @association_scope.distinct_value
        parent_aliases = parent_keys.map { |attribute| "scry_parent_#{attribute.name}" }
        child_aliases = child_keys.map { |attribute| attribute.name.to_s }
        field_aliases = fields
        dedup_projection = [
          *parent_keys.each_with_index.map { |attribute, index| attribute.as(parent_aliases[index]) },
          *child_keys.each_with_index.map { |attribute, index| attribute.as(child_aliases[index]) },
          *ranking_fields.each_with_index.map { |attribute, index| attribute.as(field_aliases[index]) }
        ]
        # DISTINCT with a joined order column deduplicates the complete select
        # list, so repeated child rows with different order values can consume
        # separate rank slots. A portable row-number window chooses the first
        # joined row under the association order for each owner/child pair.
        representative_orders = order_nodes.map do |expression, direction|
          translated = OrderExpressionTranslator.translate(expression, relation_identity_map: order_identity_map)
          translated.respond_to?(:direction) ? translated : translated.public_send(direction)
        end
        representative_orders = child_keys.map(&:asc) if representative_orders.empty?
        representative_window = Arel::Nodes::Window.new
        representative_window.partition(*(parent_keys + child_keys)).order(*representative_orders)
        representative_rank = Arel::Nodes::NamedFunction.new("ROW_NUMBER", []).over(representative_window).as("scry_representative_rank")
        representative_inner = scoped.reselect(*dedup_projection, representative_rank).arel.as("scry_representative")
        representative_table = Arel::Table.new("scry_representative")
        representative_projection = (parent_aliases + child_aliases + field_aliases).map { |name| representative_table[name] }
        dedup_manager = model.unscoped.from(representative_inner).where(
          representative_table["scry_representative_rank"].eq(1)
        ).select(*representative_projection)
        dedup_source = dedup_manager.arel.as("scry_distinct")
        ranking_source = model.unscoped.from(dedup_source)
        dedup_table = Arel::Table.new('scry_distinct')
        ranking_parent_keys = parent_aliases.map { |name| dedup_table[name] }
        ranking_child_keys = child_aliases.map { |name| dedup_table[name] }
        ranking_fields = field_aliases.map { |name| dedup_table[name] }
        order_identity_map = { child_model.arel_table => dedup_table, @association_scope.arel_table => dedup_table }
        order_nodes.flat_map { |expression, _direction| order_attributes(expression) }
          .each { |attribute| order_identity_map[attribute.relation] ||= dedup_table }
      end

      orders = order_nodes.map do |expression, direction|
        translated = OrderExpressionTranslator.translate(expression, relation_identity_map: order_identity_map)
        translated.is_a?(Arel::Nodes::Ordering) ? translated : translated.public_send(direction)
      end
      orders = ranking_child_keys.map { |attribute| attribute.asc } if orders.empty?
      ordered_names = orders.filter_map do |order|
        expression = order.respond_to?(:expr) ? order.expr : order
        expression.respond_to?(:name) ? expression.name.to_s : order.to_s[/\b[a-zA-Z_]\w*\b/]
      end
      ranking_child_keys.each do |attribute|
        orders << attribute.asc unless ordered_names.include?(attribute.name.to_s)
      end

      window = Arel::Nodes::Window.new
      window.partition(*ranking_parent_keys).order(*orders)
      rank = Arel::Nodes::NamedFunction.new('ROW_NUMBER', []).over(window).as('scry_rank')
      projection = ranking_parent_keys.each_with_index.map { |attribute, index| attribute.as(output_parent_names[index]) } +
        ranking_child_keys.map { |attribute| attribute.as(selected_child_name(child_keys[ranking_child_keys.index(attribute)].name)) } +
        ranking_fields.map { |attribute| attribute.as(selected_child_name(attribute.name)) } + [rank]
      derived = ranking_source.select(*projection).arel.as('scry_ranked')
      table = Arel::Table.new('scry_ranked')
      result = model.unscoped.from(derived).select(
        *parent_keys.map { |attribute| table[attribute.name].as(attribute.name) },
        *child_keys.map { |attribute| table[selected_child_name(attribute.name)].as(selected_child_name(attribute.name)) },
        *fields.map { |field| table[selected_child_name(field)].as(selected_child_name(field)) }
      )
      first = (@association_scope.offset_value || 0) + 1
      limit = @association_scope.limit_value || (implicit_one ? 1 : nil)
      last = limit ? first + limit - 1 : nil
      condition = table['scry_rank'].gteq(first)
      condition = condition.and(table['scry_rank'].lteq(last)) if last
      ranked = result.where(condition)
      ranked
    end

    def child_attribute_for(scope, name)
      source = scope.from_clause.value
      if source.is_a?(Arel::Nodes::TableAlias)
        source[selected_child_name(name)]
      else
        child_table[name]
      end
    end

    def scoped_relation(scoping = nil, fields: [])
      selected = selected_relation(fields: fields)
      return selected unless scoping

      attributes = child_keys_for(selected)
      scoped_keys = Compatibility.key_projection(scoping, child_model)
      if attributes.length == 1
        selected.where(attributes.first.in(scoped_keys.arel))
      else
        selected.where(Compatibility.key_membership(attributes, scoped_keys))
      end
    end

    def candidates(value)
      case value
      when ActiveRecord::Relation
        unless value.klass.base_class == child_model.base_class
          raise FilterError, 'Scry: association relation must target the associated model'
        end
        value
      when Array, Set
        canonical_candidate_relation(value)
      when Arel::SelectManager
        value
      else
        # Scalar IDs have the same set semantics as a one-element ID array.
        # Normalize them here so native predicates and custom callbacks that
        # delegate back to this query accept both operand forms.
        canonical_candidate_relation(value)
      end
    end

    def empty_value?(value)
      return value.empty? if value.is_a?(Array) || value.is_a?(Set)

      value.is_a?(ActiveRecord::Relation) && value.instance_variable_get(:@none) == true
    end

    def requested_ids(value)
      CandidateKeySet.new(self, value).projection
    end

    def candidate_projection(value)
      if value.is_a?(ActiveRecord::Relation)
        key = Compatibility.primary_keys(child_model)
        Compatibility.validate_candidate_relation!(value, key)
        candidate_relation = value
        if value.distinct_value && value.order_values.any?
          order_columns = value.order_values.filter_map do |order|
            expression = order.respond_to?(:expr) ? order.expr : order
            expression if expression.is_a?(Arel::Attributes::Attribute)
          end
          selected_names = value.select_values.flat_map { |node| Compatibility.send(:candidate_projection_columns, node) }.compact.map(&:to_s)
          missing_order_columns = order_columns.reject { |column| selected_names.include?(column.name.to_s) }
          candidate_relation = if value.select_values.empty? || missing_order_columns.empty?
            value
          else
            value.reselect(*value.select_values, *missing_order_columns)
          end
        end
        projected = candidate_relation.distinct_value ? Compatibility.with_eager_loading(candidate_relation) : candidate_relation
        projected = Compatibility.key_projection(projected, child_model)
        Compatibility.validate_candidate_projection!(projected.arel, key)
        if value.limit_value || value.offset_value || value.distinct_value
          # Preserve the selected page first; deduplicating before its limit or
          # offset changes which candidates the caller selected.
          selected = projected.arel.as('scry_selected')
          return Arel::SelectManager.new(selected).project(*key.map { |column| selected[column] }).distinct
        end
        return projected.distinct.arel
      end
      if value.is_a?(Arel::SelectManager)
        key = Compatibility.primary_keys(child_model)
        Compatibility.validate_candidate_query!(value, key, child_model.table_name)
        Compatibility.validate_candidate_projection!(value, key, single_column: true)
        selected = value.as('scry_candidates')
        return Arel::SelectManager.new(selected).project(*key.map { |column| selected[column] }).distinct
      end

      canonical_candidate_keys(value)
        .map { |tuple| tuple.length == 1 ? tuple.first : tuple }
    end

    def canonical_id(type, id)
      cast = type.cast(id)
      valid = !id.nil? && !cast.nil? && !type.serialize(id).nil?
      if type.type == :integer
        valid &&= id.is_a?(Numeric) ? id == cast : id.to_s.match?(/\A[+-]?\d+\z/)
      end
      raise FilterError, 'Scry: association ID is invalid' unless valid

      cast
    rescue ActiveModel::RangeError, ArgumentError, TypeError
      raise FilterError, 'Scry: association ID is invalid'
    end

    def polymorphic_join(target_type)
      parent_table = model.arel_table
      target_table = child_model.arel_table
      foreign_type = @reflection.foreign_type.to_s
      join_conditions = polymorphic_join_conditions(parent_table, target_table)
      join = parent_table.join(target_table).on(join_conditions)
      joined_relation = model.unscoped.joins(join.join_sources)
      type_table = @reflection.belongs_to? ? parent_table : target_table
      joined_relation = joined_relation.where(type_table[foreign_type].eq(child_model.polymorphic_name))
      [joined_relation, target_table]
    end

    def polymorphic_join_conditions(parent_table, target_table)
      if @reflection.belongs_to?
        parent_keys = Array(@reflection.foreign_key).map(&:to_s)
        child_keys = Compatibility.primary_keys(child_model)
      else
        parent_keys = Array(@reflection.active_record_primary_key).map(&:to_s)
        child_keys = Array(@reflection.foreign_key).map(&:to_s)
      end

      child_keys.zip(parent_keys).map do |child_key, parent_key|
        target_table[child_key].eq(parent_table[parent_key])
      end.reduce { |condition, next_condition| condition.and(next_condition) }
    end

    def requested_count(value)
      CandidateKeySet.new(self, value).count
    end

    def empty_candidates(value)
      count = requested_count(value)
      Arel::Nodes::Grouping.new(count).eq(Arel::Nodes.build_quoted(0))
    end

    def query_candidates?(value)
      value.is_a?(ActiveRecord::Relation) || value.is_a?(Arel::SelectManager)
    end

    def matching(value, scoping: nil)
      selection = candidates(value)
      node = requested_ids(selection)
      base = scoped_relation(scoping)
      key = child_key_attribute_for(base)
      if child_keys.length == 1
        base.where(key.in(node))
      else
        base.where(Compatibility.key_membership(
          child_keys_for(base),
          selection,
          candidate_attributes: child_keys
        ))
      end
    end

    def membership(query, owner_relation: nil)
      candidate = query.except(:order)
      candidate = candidate.reselect(*parent_keys_for(candidate))
      Compatibility.key_membership(parent_keys_for(owner_relation || model.all), candidate)
    end

    def owner_membership(rows)
      membership(rows, owner_relation: @owner_relation)
    end

    def owner_child_predicate(method, value)
      scoped = scoped_relation(@predicate_scoping)
      if value.nil? && %i[eq not_eq].include?(method.to_sym)
        condition = owner_membership(scoped)
        return method.to_sym == :eq ? Compatibility.negate(condition) : condition
      end
      child_condition = build_child_predicate(scoped, method, value)
      owner_membership(scoped.where(child_condition))
    end

    def has_any(value)
      return Compatibility.truth(false) if empty_value?(value)

      owner_membership(matching(value, scoping: @predicate_scoping))
    end

    def owner_count_at_least(value, minimum:)
      unless minimum.is_a?(Integer)
        raise FilterError, 'Scry: association cardinality minimum is invalid'
      end

      # Cardinality cannot be negative, so non-positive thresholds are true for every owner.
      return Compatibility.truth(true) if minimum <= 0

      rows = distinct_matching_rows(value)
      owner_membership(
        rows.group(*parent_keys_for(rows)).having(Arel.star.count.gteq(minimum))
      )
    end

    def not_has_any(value)
      Compatibility.negate(has_any(value))
    end

    def has_all(value)
      # Literal and query-backed empty sets agree: every requested candidate is
      # present when none were requested.
      return Compatibility.truth(true) if empty_value?(value)

      deduplicated = distinct_matching_rows(value)
      required = owner_membership(
        deduplicated.group(*parent_keys_for(deduplicated)).having(Arel.star.count.eq(requested_count(value)))
      )
      query_candidates?(value) ? empty_candidates(value).or(required) : required
    end

    def not_has_all(value)
      Compatibility.negate(has_all(value))
    end

    def only_has_any(value)
      only_has(value, required: :has_any)
    end

    def only_has_all(value)
      only_has(value, required: :has_all)
    end

    private

    def child_key_attribute_for(scope = joined_relation)
      source = scope.from_clause.value
      if source.is_a?(Arel::Nodes::TableAlias)
        source[selected_child_name(Compatibility.primary_keys(child_model).first)]
      else
        child_keys.first
      end
    end

    def distinct_matching_rows(value)
      selected = matching(value, scoping: @predicate_scoping)
      unique = selected.reselect(
        *parent_keys_for(selected),
        *child_keys_for(selected).map { |attribute| attribute.as(selected_child_name(attribute.name)) }
      ).distinct
      unique_source = unique.arel.as('scry_unique')
      model.unscoped.from(unique_source).select(Arel.sql('scry_unique.*'))
    end

    def build_child_predicate(scoped, method, value)
      child_key_attribute_for(scoped).public_send(method, value)
    end

    def only_has(value, required:)
      # Empty operands keep the same no-requirement identity for literal and
      # query-backed candidates before outside-membership is considered.
      return Compatibility.truth(required == :has_all) if empty_value?(value)

      scoped = scoped_relation(@predicate_scoping)
      ids = requested_ids(value)
      outside_condition = if child_keys.length == 1
        child_key_attribute_for(scoped).not_in(ids)
      else
        Compatibility.negate(Compatibility.key_membership(
          child_keys_for(scoped), candidates(value), candidate_attributes: child_keys
        ))
      end
      outside = owner_membership(scoped.where(outside_condition))
      required_condition = public_send(required, value)
      constrained = required_condition.and(Compatibility.negate(outside))
      required == :has_all && query_candidates?(value) ? empty_candidates(value).or(constrained) : constrained
    end

    def apply_model_scopes(scope)
      # These are host authorization constraints, so apply them to the joined
      # tables instead of rebuilding the association relation without scope.
      restricted = ModelScope.apply_to_table(scope, model: child_model, table: child_table, context: @context)
      scope.arel.join_sources.each do |join|
        table = join.respond_to?(:left) ? join.left : nil
        joined_model = table && Compatibility.model_for(table)
        next unless joined_model && ModelScope.registered?(joined_model)
        next if table.equal?(child_table)

        restricted = ModelScope.apply_to_table(restricted, model: joined_model, table:, context: @context)
      end
      restricted
    end

    def child_order_fields(order_nodes)
      order_nodes.flat_map { |expression, _direction| order_projection_attributes(expression) }
        .map { |attribute| attribute.name.to_s }.uniq
    end

    def order_projection_attributes(node)
      return [node] if node.is_a?(Arel::Attributes::Attribute)
      return [] if node.respond_to?(:name) && %w[MAX MIN SUM AVG COUNT].include?(node.name.to_s.upcase)
      return [] if node.class.name.to_s.match?(/Aggregate|NamedFunction|Max|Min|Count|Sum|Avg/)

      order_attributes(node)
    end

    def order_attributes(node)
      case node
      when Arel::Attributes::Attribute
        [node]
      when Arel::Nodes::InfixOperation
        order_attributes(node.left) + order_attributes(node.right)
      when Arel::Nodes::Grouping
        order_attributes(node.expr)
      else
        children = if node.respond_to?(:expressions)
          node.expressions
        elsif node.respond_to?(:expr)
          [node.expr]
        else
          []
        end
        children.flat_map { |child| order_attributes(child) }
      end
    end

    def canonical_candidate_relation(value)
      keys = Compatibility.primary_keys(child_model)
      canonical = canonical_candidate_keys(value)
      keys.length == 1 ? child_model.where(keys.first => canonical.map(&:first)) : child_model.where(keys => canonical)
    end

    def canonical_candidate_keys(value)
      values = value.is_a?(Set) ? value.to_a : value
      values = [values] unless values.is_a?(Array)
      values = values.map do |candidate|
        next candidate unless candidate.is_a?(child_model)

        unless candidate.persisted? && !candidate.destroyed?
          raise FilterError, 'Scry: association records must be persisted'
        end

        keys = Compatibility.primary_keys(child_model)
        tuple = keys.map { |key| candidate.public_send(key) }
        keys.length == 1 ? tuple.first : tuple
      end
      Compatibility.canonical_keys(child_model, values)
    end
  end
end
