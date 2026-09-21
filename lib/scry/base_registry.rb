# frozen_string_literal: true

module Scry
  # Shared base for PredicateRegistry and AggregateRegistry.
  #
  # Registry entries are immutable snapshots. Applications should register
  # extensions during boot or a Rails preparation callback.
  class BaseRegistry
    attr_reader :type_registry

    def initialize(type_registry: nil)
      @revision = 0
      @mutex = Monitor.new
      @type_registry = type_registry || TypeRegistry.new
      @by_name = ActiveSupport::HashWithIndifferentAccess.new
      @by_type = ActiveSupport::HashWithIndifferentAccess.new([])
      @revision += 1
      @by_type_cache = nil
      @frozen = false
    end

    def cache_key
      [@revision, @type_registry.revision]
    end

    def snapshot
      {
        by_name: @by_name.deep_dup,
        by_type: @by_type.deep_dup,
        type_registry: @type_registry.snapshot
      }
    end

    def restore(snapshot)
      @by_name = ActiveSupport::HashWithIndifferentAccess.new
      @by_type = ActiveSupport::HashWithIndifferentAccess.new([])
      snapshot[:by_name].each_value { |item| register(item) }
      @type_registry.restore(snapshot[:type_registry])
      @revision += 1
      @by_type_cache = nil
      @frozen = false
    end

    # Pre-computes type caches after application registration.
    def warm!
      @type_registry.warm!
      @by_name.each_value do |item|
        item[:types].each { |type| by_type(type) }
      end
      @frozen = true
    end

    def warmed?
      @frozen
    end

    def frozen?
      warmed?
    end

    def register(item)
      item = item.deep_dup.with_indifferent_access
      types = Array(item[:types]).map(&:to_sym)
      item[:types] = types
      @by_type.each_value { |items| items.reject! { |existing| existing[:name].to_s == item[:name].to_s } }
      item = immutable_entry(item)
      @by_name[item[:name]] = item

      types.each do |type|
        if @by_type.key?(type)
          @by_type[type] << item
        else
          @by_type[type] = [item]
        end
      end
      @revision += 1
      @by_type_cache = nil
    end

    def unregister(*names)
      names = names.map { |n| n.respond_to?(:to_sym) ? n.to_sym : n }
      @by_name.except!(*names)
      @by_type.transform_values! do |items|
        items.reject { |item| names.include?(item[:name].to_sym) }
      end
      @revision += 1
      @by_type_cache = nil
    end

    def unregister_from_type(type, *names)
      type = type.to_sym
      names = names.map { |name| name.respond_to?(:to_sym) ? name.to_sym : name }
      replacements = @by_name.each_with_object({}) do |(name, item), result|
        next unless names.include?(name.to_sym) && item[:types].include?(type)

        result[name] = item.merge(types: item[:types] - [type])
      end

      replacements.each { |name, item| @by_name[name] = immutable_entry(item) }
      # Rebuild the secondary index from canonical name entries so a removed
      # membership can never survive in a stale array entry.
      @by_type = ActiveSupport::HashWithIndifferentAccess.new([])
      @by_name.each_value do |item|
        item[:types].each do |registered_type|
          @by_type[registered_type] = [] unless @by_type.key?(registered_type)
          @by_type[registered_type] << item
        end
      end
      @revision += 1
      @by_type_cache = nil
    end

    def register_types(name, *types)
      @type_registry.register(name, *types)
    end

    def unregister_types(*names)
      @type_registry.unregister(*names)
    end

    def unregister_types_from_group(group, *types)
      @type_registry.unregister_from_group(group, *types)
    end

    def by_name(name)
      @by_name[name]
    end

    def by_type(name)
      if @type_revision != @type_registry.revision
        @by_type_cache = nil
        @type_revision = @type_registry.revision
      end
      @by_type_cache ||= {}
      @by_type_cache[name.to_sym] ||= begin
        matching_types = @type_registry.by_group(name.to_sym)
        result = Set.new
        matching_types.each do |type|
          @by_type[type].each { |item| result << item[:name] }
        end
        result.freeze
      end
    end

    def types
      @type_registry.by_group(:all)
    end

    def types_in_group(group)
      @type_registry.by_group(group)
    end

    def names
      @by_name.keys.filter_map { |name| name&.to_sym }
    end

    def metadata_for(name, locale: I18n.locale)
      item = by_name(name)
      return nil unless item

      Immutable.copy(build_metadata(name, item, locale))
    end

    def metadata_hash(item_names, locale: I18n.locale)
      metadata = item_names.each_with_object({}) do |name, hash|
        hash[name] = metadata_for(name, locale: locale)
      end
      Immutable.copy(metadata)
    end

    %i[register unregister unregister_from_type snapshot restore by_name by_type names].each do |method_name|
      original = instance_method(method_name)
      define_method(method_name) do |*args, **kwargs, &block|
        @mutex.synchronize { original.bind_call(self, *args, **kwargs, &block) }
      end
    end

    private

    def build_metadata(name, _item, locale)
      { label: translate(name, locale) }
    end

    def i18n_prefix
      raise NotImplementedError
    end

    def translate(name, locale)
      I18n.t("scry.#{i18n_prefix}.#{name}",
             locale: locale,
             default: name.to_s.humanize)
    end

    # Preserve HashWithIndifferentAccess semantics while freezing entry values.
    # Immutable.copy intentionally returns a plain Hash, which would turn the
    # string keys used by ActiveSupport's registry hash into inaccessible
    # symbol keys.
    def immutable_entry(item)
      Immutable.copy(item)
    end
  end
end
