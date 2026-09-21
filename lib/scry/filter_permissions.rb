# frozen_string_literal: true

module Scry
  class FilterPermissions
    EMPTY_SET = Set.new.freeze
    CacheEntry = Struct.new(:value, :failure, keyword_init: true)

    VALID_TYPES = %i[
      associations
      properties
      predicates
      type_predicates
      property_predicates
      custom_property_filters
      aggregates
      order
      property_transforms
      model
    ].freeze

    def initialize(klass:)
      @klass = klass

      VALID_TYPES.each do |type|
        __send__(:"#{type}=", FilterPermissionsChain.new(type:))
      end
    end

    MAX_CACHE_SIZE = 1000

    # Thread-local cache accessor. Each thread gets its own isolated cache store,
    # preventing cross-thread contamination in multi-threaded servers.
    # Uses LRU eviction when the cache grows beyond MAX_CACHE_SIZE: on each hit,
    # the entry is moved to the end (most recently used). On eviction, the oldest
    # half (least recently used) is removed. Ruby Hash preserves insertion order,
    # so delete + re-insert moves an entry to the tail.
    def thread_cache(name, key, diagnostic_context:)
      store = Thread.current[:scry_caches] ||= {}
      # Discovery traverses other models, so any policy change invalidates
      # dependency-derived entries without retaining a graph of model classes.
      # Keep the signature stable for the lifetime of a request. The previous
      # database identity tuple included per-call schema cache object ids, which
      # could discard a cached callback failure between discovery and filtering.
      # Permission and schema mutations already advance the chain generation.
      table_name = @klass.respond_to?(:table_name) ? @klass.table_name : nil
      signature = [object_id, Scry.configuration.cache_key,
                   FilterPermissionsChain.generation, table_name]
      versions = Thread.current[:scry_cache_versions] ||= {}
      if versions[@klass] != signature
        store.delete(@klass)
        versions[@klass] = signature
      end
      klass_store = store[@klass] ||= {}
      cache_key = [name, key]
      if klass_store.key?(cache_key)
        entry = klass_store[cache_key]
        klass_store.delete(cache_key)
        klass_store[cache_key] = entry
        if entry.is_a?(CacheEntry) && entry.failure
          failure = entry.failure
          diagnostic = failure.is_a?(Diagnostic) ? failure : Diagnostic.new(
            category: :callback_error, code: :callback_error, path: [], message: failure
          )
          raise CallbackFailure.new(diagnostic.message, diagnostic:)
        end
        return entry.is_a?(CacheEntry) ? entry.value : entry
      end

      if klass_store.size >= MAX_CACHE_SIZE
        evict_count = klass_store.size / 2
        klass_store.keys.first(evict_count).each { |k| klass_store.delete(k) }
      end

      begin
        value = yield
      rescue CallbackFailure => error
        failure = error.diagnostic || error.message.dup.freeze
        klass_store[cache_key] = CacheEntry.new(value: nil, failure: failure).freeze
        raise
      else
        immutable_value = Immutable.copy(value)
        klass_store[cache_key] = CacheEntry.new(value: immutable_value, failure: nil).freeze
        immutable_value
      end
    end

    def reset_permissions(*types)
      types.each do |type|
        self[type].reset_permissions
      end
    end

    def [](type)
      return __send__(type) if VALID_TYPES.include?(type.to_sym)

      raise ArgumentError, "type must be one of #{VALID_TYPES.inspect}"
    end

    def deep_dup(klass:)
      new_permissions = self.class.new(klass:)
      VALID_TYPES.each do |type|
        new_permissions.__send__(:"#{type}=", __send__(type).deep_dup(klass: klass))
      end
      new_permissions
    end

    def allowed_associations(context)
      thread_cache(:allowed_associations, context, diagnostic_context: context) do
        reflections = @klass.reflect_on_all_associations
        default_associations = reflections.map { |a| a.name.to_sym }
        initial = Scry.configuration.strict ? [] : default_associations
        result = PermissionResolver.reduce(initial,
                                           permissions: associations.permissions,
                                           context:,
                                           universe: default_associations,
                                           model: @klass)
        selected = result.select do |assoc|
          reflection = @klass.reflect_on_association(assoc.to_sym)
          next false unless reflection
          if reflection.polymorphic?
            permitted_targets = allowed_association_targets(assoc, context)
            next !permitted_targets.empty?
          end
          begin
            target = reflection.klass
          rescue NameError, ArgumentError
            next false
          end
          target.respond_to?(:scry_permissions) && target.model_allowed?(context)
        end.to_set
        selected
      end
    end

    def allowed_association_targets(association, context)
      thread_cache(:allowed_association_targets, [association.to_sym, context], diagnostic_context: context) do
        reflection = @klass.reflect_on_association(association.to_sym)
        next {}.freeze unless reflection&.polymorphic?

        targets = @klass.targets_for(association)
        allowed = targets.each_with_object({}) do |(name, entry), result|
          model = entry[:model]
          next unless model.respond_to?(:scry_permissions)
          next unless model.model_allowed?(context)

          result[name.to_s] = model
        end
        Immutable.copy(allowed)
      end
    end

    def allowed_order_properties(context)
      thread_cache(:allowed_order_properties, context, diagnostic_context: context) do
        universe = allowed_properties(context)
        PermissionResolver.reduce(universe,
                                  permissions: self[:order].permissions,
                                  context:, universe: universe, model: @klass).to_set
      end
    end

    def allowed_custom_property_filters(context)
      thread_cache(:allowed_custom_property_filters, context, diagnostic_context: context) do
        custom_property_entries(context).each_with_object({}) do |(key, entry), result|
          result[key] = entry[:filter]
        end
      end
    end

    # Optional metadata for virtual properties is kept separate from the
    # executable filter definition for backwards compatibility.
    def custom_property_metadata(context)
      thread_cache(:custom_property_metadata, context, diagnostic_context: context) do
        custom_property_entries(context).each_with_object({}) do |(key, entry), result|
          result[key] = entry[:metadata] unless entry[:metadata].empty?
        end
      end
    end

    def custom_property_entries(context)
      thread_cache(:custom_property_entries, context, diagnostic_context: context) do
        custom_property_filters.permissions.reduce({}) do |acc, permission|
          map = Scry.invoke_callback(
            label: "custom property permission", model: @klass, context:, path: []
          ) { permission[:block].call(context) } || {}
          unless map.is_a?(Hash)
            raise Scry::FilterError,
              "Scry: custom property filter must return a Hash, got #{map.class}"
          end

          list_type = permission[:list_type]
          entries = map.each_with_object({}) do |(key, definition), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise Scry::FilterError, "Scry: custom property key must be a name"
            end
            property = key.to_sym
            result[property] = if %i[whitelist blacklist excludelist].include?(list_type)
              nil
            else
              normalize_custom_property_entry(
                definition, custom_property_metadata_for(permission[:metadata], property)
              )
            end
          end

          case list_type
          when :whitelist
            acc.select { |k, _| entries.key?(k) }
          when :blacklist, :excludelist
            acc.reject { |k, _| entries.key?(k) }
          when :includelist, nil
            acc.merge(entries)
          else
            raise Scry::FilterError,
              "Scry: unrecognized list_type #{list_type.inspect}"
          end
        end
      end
    end

    def allowed_properties(context)
      thread_cache(:allowed_properties, context, diagnostic_context: context) do
        columns = @klass.columns.map { |c| c.name.to_sym }
        foreign_keys = @klass.reflect_on_all_associations.select { |a| a.macro == :belongs_to }.flat_map(&:foreign_key).map(&:to_sym)
        encrypted_attributes = @klass.respond_to?(:encrypted_attributes) ? Array(@klass.encrypted_attributes).map(&:to_sym) : []
        all_properties = columns + allowed_custom_property_filters(context).keys - encrypted_attributes - foreign_keys
        base_properties = if Scry.configuration.strict
          allowed_custom_property_filters(context).keys
        else
          all_properties
        end

        PermissionResolver.reduce(base_properties,
                                  permissions: self[:properties].permissions,
                                  context:,
                                  universe: all_properties, model: @klass).to_set
      end
    end

    def allowed_property_predicates(context)
      thread_cache(:allowed_property_predicates, context, diagnostic_context: context) do
        (allowed_associations(context) | allowed_properties(context)).each_with_object({}) do |property, hash|
          hash[property] = predicates_by_property(context)[property]
        end
      end
    end

    # Aggregate comparisons use the registered result type, which may differ
    # from the input property type (for example COUNT over a timestamp).
    def allowed_aggregate_predicates(context, type: :numerical)
      thread_cache(:allowed_aggregate_predicates, [context, type], diagnostic_context: context) do
        registry = Scry.configuration.predicate_registry
        (predicates_by_type(context)[type] || []).select do |name|
          Array(registry.by_name(name)[:applies_to] || [:property]).include?(:aggregate)
        end.to_set
      end
    end

    # Returns true if the model is allowed to be filtered for the given context.
    # Semantics: default allow. If a :model rule exists, its block is evaluated; the last
    # added rule wins. Rules should return true (allow), false (deny), or nil (no decision).
    def model_allowed?(context)
      thread_cache(:model_allowed, context, diagnostic_context: context) do
        permission = self[:model].permissions.to_a.last
        return true unless permission

        result = Scry.invoke_callback(
          label: "model permission", model: @klass, context:, path: []
        ) { permission[:block].call(context) }
        unless [true, false, nil].include?(result)
          Scry.logger.warn("Scry: invalid model permission result of type #{result.class}; expected true/false/nil")
          return false
        end

        result.nil? ? true : !!result
      end
    end

    # Returns a structured hash of all filter permissions for the given context
    def to_h(context = nil, locale: I18n.locale)
      return Scry.empty_information unless model_allowed?(context)

      result = {
        properties: properties_with_labels(context, locale: locale),
        associations: associations_with_labels(context, locale: locale),
        predicates: predicate_metadata(context, locale: locale),
        property_predicates: allowed_property_predicates(context),
        order: allowed_order_properties(context),
        association_targets: association_targets(context),
        aggregates: allowed_aggregates(context, propagate_callback_failure: true),
        aggregate_metadata: aggregate_metadata(context, locale: locale),
        aggregate_predicates: aggregate_predicates(context)
      }
      Immutable.copy(result)
    end

    def association_targets(context)
      thread_cache(:association_targets, context, diagnostic_context: context) do
        allowed_associations(context).each_with_object({}) do |association, result|
          targets = allowed_association_targets(association, context)
          result[association.to_s] = targets.keys unless targets.empty?
        end
      end
    end

    # Clears memoized permission caches so changes in configuration are reflected
    def clear_caches!
      store = Thread.current[:scry_caches]
      return unless store

      store.delete(@klass)
    end

    # Returns properties with translated labels
    # @param context [Object] The authorization context (usually current user)
    # @param locale [Symbol] The locale to translate to
    # @return [Array<Hash>] Array of hashes with :key and :label
    def properties_with_labels(context, locale: I18n.locale)
      thread_cache(:properties_with_labels, [context, locale], diagnostic_context: context) do
        allowed_properties(context).map do |property|
          custom_metadata = custom_property_metadata(context)[property.to_sym] || {}
          {
            key: property.to_s,
            label: custom_metadata[:label] || translate_property(property, locale),
            type: (custom_metadata[:type] || Compatibility.property_type(@klass, property)).to_s
          }
        end
      end
    end

    # Returns associations with translated labels
    # @param context [Object] The authorization context (usually current user)
    # @param locale [Symbol] The locale to translate to
    # @return [Array<Hash>] Array of hashes with :key and :label
    def associations_with_labels(context, locale: I18n.locale)
      thread_cache(:associations_with_labels, [context, locale], diagnostic_context: context) do
        allowed = allowed_associations(context)
        labeled = allowed.filter_map do |association|
          reflection = @klass.reflect_on_association(association.to_sym)

          # A polymorphic reflection deliberately has no single `klass`.
          # Its registered, permitted targets were already checked by
          # `allowed_associations`; metadata only needs the association name.
          if reflection&.polymorphic?
            {
              key: association.to_s,
              label: translate_association(association, locale)
            }
          else

            begin
              reflection&.klass&.name
            rescue NameError => e
              Scry.logger.warn(
                "Skipping association #{association} for #{@klass.name}: #{e.class}"
              )
              next
            end

            {
              key: association.to_s,
              label: translate_association(association, locale)
            }
          end
        end
        labeled
      end
    end

    # Returns metadata for all predicates allowed in the given context
    # @param context [Object] The authorization context (usually current user)
    # @param locale [Symbol] The locale to translate to
    # @return [Hash] Hash mapping predicate names to their metadata
    def predicate_metadata(context, locale: I18n.locale)
      thread_cache(:predicate_metadata, [context, locale], diagnostic_context: context) do
        # Collect predicates exposed by ordinary filters and executable
        # aggregates. Aggregate-only capabilities must be discoverable too.
        all_predicates = allowed_property_predicates(context).each_with_object(Set.new) { |(_, preds), set| set.merge(preds) }
        all_predicates.merge(allowed_predicates(context))
        aggregate_predicates(context).each_value do |aggregates|
          aggregates.each_value do |predicates|
            if predicates.is_a?(Hash)
              predicates.each_value { |names| all_predicates.merge(names) }
            else
              all_predicates.merge(predicates)
            end
          end
        end

        Scry.configuration.predicate_registry.metadata_hash(all_predicates, locale: locale)
      end
    end

    # Returns executable aggregate metadata, including resolved property types.
    def aggregate_metadata(context, locale: I18n.locale)
      thread_cache(:aggregate_metadata, [context, locale], diagnostic_context: context) do
        aggregate_capabilities(context).each_with_object({}) do |(association, aggregates), result|
          result[association] = aggregates.each_with_object({}) do |(name, capability), entries|
            fields = capability[:fields]
            child = capability[:child]
            definition = Scry.configuration.aggregate_registry.metadata_for(name, locale: locale)
            next unless definition
            metadata = definition.dup
            metadata[:types] = Array(metadata[:types]).map(&:to_s)
            metadata[:result_type] = metadata[:result_type].to_s
            metadata[:adapters] = Array(metadata[:adapters]).map(&:to_s) if metadata[:adapters]
            if definition[:result_type].to_sym == :property && fields != true
              metadata[:result_types] = fields.each_with_object({}) do |field, types|
                types[field.to_s] = Compatibility.property_type(child, field).to_s
              end
            end
            entries[name] = metadata
          end
          result.delete(association) if result[association].empty?
        end
      end
    end

    # Returns predicates permitted for each executable aggregate. Property
    # result aggregates expose a per-field mapping because their result type
    # depends on the selected child property.
    def aggregate_predicates(context)
      thread_cache(:aggregate_predicates, context, diagnostic_context: context) do
        aggregate_capabilities(context).each_with_object({}) do |(association, aggregates), result|
          result[association] = aggregates.each_with_object({}) do |(name, capability), entries|
            fields = capability[:fields]
            child = capability[:child]
            definition = capability[:definition]
            if definition[:result_type].to_sym == :property && fields != true
              entries[name] = fields.each_with_object({}) do |field, predicates|
                predicates[field.to_s] = allowed_aggregate_predicates(
                  context, type: Compatibility.property_type(child, field)
                ).to_a
              end
            else
              entries[name] = allowed_aggregate_predicates(context, type: definition[:result_type]).to_a
            end
          end
          result.delete(association) if result[association].empty?
        end
      end
    end

    # Resolve reflection, child model, and aggregate definition once for all
    # discovery serializers. Filtering still uses allowed_aggregates directly.
    def aggregate_capabilities(context)
      thread_cache(:aggregate_capabilities, context, diagnostic_context: context) do
        allowed_aggregates(context).each_with_object({}) do |(association, aggregates), result|
          reflection = @klass.reflect_on_association(association)
          next unless reflection

          child = reflection.klass
          entries = aggregates.each_with_object({}) do |(name, fields), capabilities|
            definition = Scry.configuration.aggregate_registry.by_name(name)
            next unless definition

            capabilities[name] = { fields:, child:, definition: }
          end
          result[association] = entries unless entries.empty?
        end
      end
    end

    # Returns mapping: { association => { aggregate_name => true|:all|Set(attributes) } }
    # Uses the aggregate registry to determine which aggregates can apply to which attribute types
    def allowed_aggregates(context, propagate_callback_failure: false)
      thread_cache(:allowed_aggregates, context, diagnostic_context: context) do
        base = build_default_aggregates(context)
        allowed_assoc_names = allowed_associations(context).map(&:to_s).to_set

        resolved = HashPermissionResolver.reduce(
          base, permissions: aggregates.permissions, context:, model: @klass
        ) do |acc, map, list_type|
          case list_type
          when :whitelist
            whitelist_aggregate_permissions(acc, map)
          when :includelist
            merge_aggregate_permissions(acc, map, allowed_assoc_names)
          when :blacklist, :excludelist
            remove_aggregate_permissions(acc, map, allowed_assoc_names)
          end
        end
        universe = build_default_aggregates(context, strict: false)
        resolved.each_with_object({}) do |(association, entries), result|
          allowed = universe[association] || {}
          constrained = entries.each_with_object({}) do |(name, fields), values|
            next unless allowed.key?(name)
            available = allowed[name]
            values[name] = if available == true
              fields
            elsif fields == true || fields == :all
              available
            else
              fields.to_set & available
            end
            values.delete(name) if values[name].respond_to?(:empty?) && values[name].empty?
          end
          result[association] = constrained unless constrained.empty?
        end
      end
    rescue CallbackFailure
      raise if propagate_callback_failure

      {}
    end

    # Returns the immutable set of predicates authorized for this model and context.
    def allowed_predicates(context)
      registry = Scry.configuration.predicate_registry
      predicates_by_auth(context).select do |name|
        definition = registry.by_name(name)
        definition && Array(definition[:applies_to] || [:property]).include?(:computed)
      end.to_set
    end

    # Computed predicates need both expression applicability and each source
    # property's predicate permission. The latter remains property-specific
    # even though the predicate itself is registered for the computed kind.
    def allowed_expression_predicates(context, properties)
      properties = Array(properties).map(&:to_sym)
      return Set.new if properties.empty?

      properties.reduce(nil) do |allowed, property|
        current = predicates_by_property(context, kind: :computed)[property] || []
        allowed ? allowed & current : current
      end.to_set
    end

    private

    attr_reader :klass
    attr_accessor :associations, :properties, :predicates, :type_predicates, :property_predicates,
                  :custom_property_filters, :aggregates, :order, :property_transforms, :model

    CUSTOM_PROPERTY_METADATA_KEYS = %i[type label predicates accepted_predicates].freeze
    CUSTOM_PROPERTY_PREDICATES = %i[eq_true eq_false].freeze

    def custom_property_metadata_for(metadata, property)
      metadata = metadata.to_h if metadata.respond_to?(:to_h)
      return {} unless metadata.is_a?(Hash)

      # Support both one metadata object shared by all returned properties and
      # a map keyed by property name.
      property_metadata = metadata[property] || metadata[property.to_s]
      metadata = property_metadata if property_metadata.is_a?(Hash)
      if property_metadata.nil? && metadata.values.all? { |value| value.is_a?(Hash) }
        return {}
      end
      normalize_custom_property_metadata(metadata)
    end

    def normalize_custom_property_entry(definition, permission_metadata)
      if definition.is_a?(Hash) && (definition.key?(:filter) || definition.key?('filter'))
        unless definition.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
          raise FilterError, 'Scry: custom property metadata keys must be names'
        end
        wrapper = definition.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
        filter = wrapper[:filter]
        unknown_keys = wrapper.keys - [:filter] - CUSTOM_PROPERTY_METADATA_KEYS
        unless unknown_keys.empty?
          raise FilterError, 'Scry: unsupported custom property metadata key'
        end
        inline_metadata = normalize_custom_property_metadata(wrapper.except(:filter))
      else
        filter = definition
        inline_metadata = {}
      end

      raise FilterError, 'Scry: custom property filter returned nil' if filter.nil?

      unless filter.is_a?(Hash)
        raise FilterError, 'Scry: custom property filter definition must be a Hash'
      end
      metadata = permission_metadata.merge(inline_metadata.symbolize_keys)
      {filter: filter, metadata: metadata}
    end

    def normalize_custom_property_metadata(metadata)
      normalized = metadata.each_with_object({}) do |(key, value), result|
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise FilterError, 'Scry: custom property metadata keys must be names'
        end
        key = key.to_sym
        unless CUSTOM_PROPERTY_METADATA_KEYS.include?(key)
          raise FilterError, 'Scry: unsupported custom property metadata key'
        end
        next if value.nil?
        result[key] = value
      end

      if normalized.key?(:type)
        unless normalized[:type].is_a?(String) || normalized[:type].is_a?(Symbol)
          raise FilterError, 'Scry: custom property metadata type must be a name'
        end
        unless normalized[:type].to_sym == :boolean
          raise FilterError, 'Scry: custom property metadata type must be boolean'
        end
        normalized[:type] = :boolean
      end
      if normalized.key?(:label) && !normalized[:label].is_a?(String)
        raise FilterError, 'Scry: custom property metadata label must be a String'
      end
      %i[predicates accepted_predicates].each do |key|
        next unless normalized.key?(key)
        tokens = normalized[key]
        tokens = tokens.to_a if tokens.is_a?(Set)
        tokens = [tokens] if tokens.is_a?(String) || tokens.is_a?(Symbol)
        unless tokens.is_a?(Array) && tokens.all? { |token| token.is_a?(String) || token.is_a?(Symbol) }
          raise FilterError, 'Scry: custom property predicates must contain names'
        end
        normalized[key] = tokens.map(&:to_sym)
        unless normalized[key].all? { |token| CUSTOM_PROPERTY_PREDICATES.include?(token) }
          raise FilterError,
            'Scry: custom property predicates must be eq_true or eq_false'
        end
      end
      normalized
    end

    def predicates_by_property(context, kind: nil)
      thread_cache(:predicates_by_property, [context, kind], diagnostic_context: context) do
        registry = Scry.configuration.predicate_registry
        columns = @klass.columns.index_by { |column| column.name.to_sym }
        associations = @klass.reflect_on_all_associations.index_by(&:name)
        rules = property_predicates.permissions.map do |permission|
          [permission, policy_map(permission, context)]
        end
        (allowed_properties(context) | allowed_associations(context)).each_with_object({}) do |property, result|
          metadata = custom_property_metadata(context)[property] || {}
          type = columns[property] && Compatibility.property_type(@klass, property)
          type ||= metadata[:type]&.to_sym || associations[property]&.macro
          universe = type ? registry.by_type(type).to_a : registry.names
          current = type ? (predicates_by_type(context)[type] || []) : predicates_by_auth(context)
          rules.each do |permission, map|
            current = apply_policy_predicates(permission[:list_type], current, map[property], universe)
          end
          accepted = metadata[:predicates] || metadata[:accepted_predicates]
          if custom_property_metadata(context).key?(property) || allowed_custom_property_filters(context).key?(property)
            accepted = CUSTOM_PROPERTY_PREDICATES if accepted.nil?
          end
          if accepted
            accepted = Array(accepted.is_a?(Set) ? accepted.to_a : accepted).flat_map do |token|
              token = token.to_sym
              token == :all ? universe : registry.by_name(token) ? [token] : registry.by_type(token).to_a
            end
            current &= accepted
          end
          applicability_kind = kind || (associations[property] ? :association : :property)
          result[property] = current.select do |name|
            definition = registry.by_name(name)
            definition && Array(definition[:applies_to] || [:property]).include?(applicability_kind) && Compatibility.supported?(@klass, definition)
          end
        end
      end
    end

    def predicates_by_type(context)
      thread_cache(:predicates_by_type, context, diagnostic_context: context) do
        registry = Scry.configuration.predicate_registry
        rules = type_predicates.permissions.map do |permission|
          [permission, policy_map(permission, context)]
        end
        registry.types.each_with_object({}.with_indifferent_access) do |type, result|
          universe = registry.by_type(type).to_a
          current = predicates_by_auth(context) & universe
          matching = rules.flat_map do |permission, map|
            entries = map.select { |group, _| registry.type_registry.descendants(group).include?(type.to_sym) }
            entries = {all: nil} if entries.empty? && permission[:list_type] == :whitelist
            entries.map { |group, predicates| [group.to_sym, permission[:list_type], predicates] }
          end
          # Ancestor rules precede their descendants; equal and unrelated
          # groups retain declaration order.
          groups = matching.map(&:first).uniq
          matching = matching.each_with_index.sort_by do |(group, _, _), index|
            ancestors = groups.count do |other|
              other != group && registry.type_registry.descendants(other).include?(group) &&
                !registry.type_registry.descendants(group).include?(other)
            end
            [ancestors, index]
          end.map(&:first)
          matching.each do |_, operation, predicates|
            current = apply_policy_predicates(operation, current, predicates, universe)
          end
          result[type] = current.select { |name| Compatibility.supported?(@klass, registry.by_name(name)) }
        end
      end
    end

    def policy_map(permission, context)
      value = Scry.invoke_callback(
        label: "predicate permission", model: @klass, context:, path: []
      ) { permission[:block].call(context) }
      unless value.is_a?(Hash)
        raise FilterError, 'Scry: predicate permission must return a Hash'
      end
      value.each_with_object({}) do |(key, predicates), result|
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise FilterError, 'Scry: predicate permission keys must be names'
        end
        unless predicates.nil? || predicates == :all || predicates == 'all' || predicates.is_a?(Array) || predicates.is_a?(Set)
          raise FilterError, 'Scry: predicate permission values must be a collection or :all'
        end
        result[key.to_sym] = if predicates == :all || predicates == 'all'
          :all
        elsif predicates
          predicates.map do |name|
            unless name.is_a?(String) || name.is_a?(Symbol)
              raise FilterError, 'Scry: predicate permission entries must be names'
            end
            name.to_sym
          end
        end
      end
    rescue CallbackFailure
      raise
    rescue NameError, FilterError
      raise
    rescue StandardError => error
      raise FilterError, "Scry: permission block raised #{error.class}"
    end

    def apply_policy_predicates(operation, current, incoming, universe)
      selected = incoming == :all ? universe : Array(incoming) & universe
      case operation
      when :whitelist then current & selected
      when :blacklist, :excludelist then current - selected
      when :includelist then incoming == :all ? universe : current | selected
      else raise FilterError, "Scry: unrecognized list_type #{operation.inspect}"
      end
    end

    def predicates_by_auth(context)
      thread_cache(:predicates_by_auth, context, diagnostic_context: context) do
        registry = Scry.configuration.predicate_registry
        global_predicates = registry.names.select { |name| Compatibility.supported?(@klass, registry.by_name(name)) }
        initial = Scry.configuration.strict ? [] : global_predicates

        PermissionResolver.reduce(initial,
                                  permissions: predicates.permissions,
                                  context:,
                                  universe: global_predicates, model: @klass)
      end
    end

    # Builds the default aggregate permission map based on type registry.
    # In strict mode, returns empty (requires explicit whitelist).
    def build_default_aggregates(context, strict: Scry.configuration.strict)
      return {} if strict

      agg_names = Scry.configuration.aggregate_registry.names
      type_columns_cache = {}
      allowed_associations(context).each_with_object({}) do |assoc, base|
        reflection = @klass.reflect_on_association(assoc)
        next unless reflection
        next if reflection.polymorphic?

        begin
          associated_model = reflection.klass
        rescue NameError => e
          Scry.logger.warn(
            "Scry: aggregate association model for #{assoc} unavailable (#{e.class})"
          )
          next
        end

        type_columns = (type_columns_cache[associated_model] ||= build_type_columns_index(associated_model, context))
        base[assoc.to_s] = build_aggregates_for_model(associated_model, agg_names, type_columns: type_columns, context: context)
      end
    end

    # Returns { agg_name => true|Set(column_names) } for a single associated model.
    def build_aggregates_for_model(associated_model, agg_names, type_columns: nil, context: nil)
      type_columns ||= build_type_columns_index(associated_model, context)

      agg_names.each_with_object({}) do |agg_name, result|
        aggregate = Scry.configuration.aggregate_registry.by_name(agg_name)
        next unless aggregate && Compatibility.supported?(associated_model, aggregate)

        agg_key = agg_name.to_s
        if !aggregate[:property]
          result[agg_key] = true
        elsif type_columns
          allowed_attrs = Set.new
          aggregate[:types].each do |type_group|
            supported_types = Scry.configuration.predicate_registry.types_in_group(type_group)
            supported_types.each { |t| allowed_attrs.merge(type_columns[t]) }
          end
          result[agg_key] = allowed_attrs unless allowed_attrs.empty?
        end
      end
    end

    # Pre-computes column type → column name index for an associated model.
    def build_type_columns_index(associated_model, context)
      return nil unless associated_model.respond_to?(:columns)

      permitted = associated_model.scry_permissions.allowed_properties(context)
      associated_model.columns.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |col, index|
        next unless permitted.include?(col.name.to_sym)
        index[Compatibility.property_type(associated_model, col.name)] << col.name
      end
    end

    def whitelist_aggregate_permissions(acc, map)
      result = {}
      map.to_h.each do |assoc, aggs|
        assoc_key = assoc.to_s
        next unless acc[assoc_key]
        result[assoc_key] = {}
        aggs.to_h.each do |agg_name, val|
          agg_key = agg_name.to_s
          next unless acc[assoc_key][agg_key]
          current = acc[assoc_key][agg_key]
          if val == true || val == :all
            result[assoc_key][agg_key] = current
          elsif current == true
            result[assoc_key][agg_key] = Set.new(Array(val).map(&:to_s))
          else
            intersection = current.to_set & Set.new(Array(val).map(&:to_s))
            result[assoc_key][agg_key] = intersection unless intersection.empty?
          end
        end
        result.delete(assoc_key) if result[assoc_key].empty?
      end
      result
    end

    def merge_aggregate_permissions(acc, map, allowed_assoc_names)
      map.to_h.each do |assoc, aggs|
        assoc_key = assoc.to_s
        next unless allowed_assoc_names.include?(assoc_key)
        acc[assoc_key] ||= {}
        aggs.to_h.each do |agg_name, val|
          agg_key = agg_name.to_s
          current = acc[assoc_key][agg_key]
          case val
          when true, :all
            acc[assoc_key][agg_key] = true
          else
            vals = Array(val).map(&:to_s).to_set
            next if current == true
            acc[assoc_key][agg_key] = (current || Set.new) | vals
          end
        end
      end
      acc
    end

    def remove_aggregate_permissions(acc, map, _allowed_assoc_names)
      map.to_h.each do |assoc, aggs|
        assoc_key = assoc.to_s
        next unless acc[assoc_key]
        aggs.to_h.each do |agg_name, val|
          agg_key = agg_name.to_s
          next unless acc[assoc_key][agg_key]
          case val
          when true, :all
            acc[assoc_key].delete(agg_key)
          else
            vals = Array(val).map(&:to_s).to_set
            current = acc[assoc_key][agg_key]
            if current == true
              acc[assoc_key].delete(agg_key)
            else
              set = current - vals
              set.empty? ? acc[assoc_key].delete(agg_key) : acc[assoc_key][agg_key] = set
            end
          end
        end
        acc.delete(assoc_key) if acc[assoc_key].empty?
      end
      acc
    end

    # Translates a property name using Rails i18n conventions
    def translate_property(property, locale)
      I18n.with_locale(locale) do
        @klass.human_attribute_name(property)
      end
    end

    # Translates an association name using I18n or the associated model's name
    def translate_association(association, locale)
      reflection = @klass.reflect_on_association(association)
      return association.to_s.humanize unless reflection

      if @klass.respond_to?(:model_name)
        i18n_key = "activerecord.associations.#{@klass.model_name.i18n_key}.#{association}"
        if I18n.exists?(i18n_key, locale)
          return I18n.t(i18n_key, locale: locale)
        end
      end

      association.to_s.humanize
    end
  end
end
