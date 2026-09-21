# frozen_string_literal: true

module Scry
  class TypeRegistry
    attr_reader :revision

    def initialize
      @revision = 0
      @mutex = Monitor.new
      @by_group = ActiveSupport::HashWithIndifferentAccess.new([])
      @by_group_cache = {}
      @frozen = false
    end

    def register(name, *types)
      @mutex.synchronize do
        name = name.to_sym
        @by_group[name] = (@by_group[name] + types.map(&:to_sym)).uniq
        invalidate_cache!
      end
    end

    # Pre-computes all group closures after application registration.
    def warm!
      @mutex.synchronize do
        @by_group.keys.each { |name| by_group(name.to_sym) }
        by_group(:all)
        @frozen = true
      end
    end

    def warmed?
      @frozen
    end

    def frozen?
      warmed?
    end

    def unregister(*names)
      @mutex.synchronize do
        names.map(&:to_sym).each do |name|
          @by_group.delete(name) if @by_group.key?(name)
          @by_group.transform_values! { |types| types - [name] }
        end
        invalidate_cache!
      end
    end

    def unregister_from_group(group, *names)
      @mutex.synchronize do
        @by_group[group.to_sym] = @by_group[group].reject { |type| names.map(&:to_sym).include?(type.to_sym) }
        invalidate_cache!
      end
    end

    def snapshot
      @mutex.synchronize { @by_group.deep_dup }
    end

    def restore(snapshot)
      @mutex.synchronize do
        @by_group = snapshot.deep_dup
        @frozen = false
        invalidate_cache!
      end
    end

    # Returns the transitive closure for a type group: the group itself,
    # all ancestor groups that contain it, all descendant types it contains,
    # plus :all. Results are cached and invalidated on register/unregister.
    def by_group(name)
      @mutex.synchronize do
        name = name.to_sym
        return @by_group_cache[name] if @by_group_cache.key?(name)

        result = if name == :all
                   [:all] + child_types_for(:all)
                 else
                   [:all] | group_types_for(name) | [name] | child_types_for(name)
                 end

        @by_group_cache[name] = result.uniq.freeze
      end
    end

    def descendants(name)
      @mutex.synchronize { ([name.to_sym] | child_types_for(name.to_sym)).uniq.freeze }
    end

    private

    def invalidate_cache!
      @revision += 1
      @by_group_cache = {}
    end

    def child_types_for(name, visited = Set.new, stack = Set.new)
      if stack.include?(name)
        Scry.logger.warn("Scry::TypeRegistry: cycle detected in type hierarchy at #{name.inspect} (visited: #{visited.to_a.inspect})") unless name == :all
        return []
      end
      return [] if visited.include?(name) && name != :all
      visited.add(name)
      stack.add(name)

      types =
        if name == :all
          (@by_group.keys.map(&:to_sym) - [:all]) | @by_group[:all]
        elsif !@by_group.key?(name)
          return []
        else
          @by_group[name]
        end

      types = types.reject { |t| t == name } # skip trivial self-references

      types.flat_map do |type|
        [type] | child_types_for(type, visited, stack)
      end
    ensure
      stack&.delete(name)
    end

    def group_types_for(name, visited = Set.new, stack = Set.new)
      if stack.include?(name)
        Scry.logger.warn("Scry::TypeRegistry: cycle detected in type hierarchy at #{name.inspect} (visited: #{visited.to_a.inspect})") unless name == :all
        return []
      end
      return [] if visited.include?(name)
      visited.add(name)
      stack.add(name)

      parents = @by_group.select { |_, value| value.include?(name) }.keys.map(&:to_sym)
      parents = parents.reject { |p| p == name } # skip trivial self-references
      return [] unless parents.any?

      parents.flat_map do |parent|
        group_types_for(parent, visited, stack)
      end | parents
    ensure
      stack&.delete(name)
    end
  end
end
