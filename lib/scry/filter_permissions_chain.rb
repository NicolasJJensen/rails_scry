# frozen_string_literal: true

module Scry
  class FilterPermissionsChain
    attr_reader :revision

    @generation = 0
    @generation_mutex = Monitor.new

    class << self
      def generation
        @generation_mutex.synchronize { @generation }
      end

      def invalidate!
        @generation_mutex.synchronize { @generation += 1 }
      end
    end

    def initialize(type:)
      @revision = 0
      @mutex = Monitor.new
      self.type = type
      self.permissions_list = []
    end

    def add_permission(permission)
      @mutex.synchronize do
        if @type == :model
          unless permissions_list.empty?
            Scry.logger.warn("Scry: multiple :model permissions defined; keeping only the last one")
            self.permissions_list = []
          end
        end
        permissions_list << Immutable.copy(permission.deep_dup)
        @revision += 1
        self.class.invalidate!
      end
    end

    def deep_dup(klass: nil)
      @mutex.synchronize do
        new_chain = self.class.new(type:)
        copied = permissions_list.map do |permission|
          item = permission.deep_dup
          if klass && item[:block].is_a?(Filterable::NamedCallback)
            item[:block] = item[:block].for_model(klass)
          end
          Immutable.copy(item)
        end
        new_chain.send(:permissions_list=, copied)
        new_chain
      end
    end

    def permissions(&block)
      return permissions_list_snapshot.each(&block) if block

      permissions_list_snapshot.each
    end

    def reset_permissions
      @mutex.synchronize do
        self.permissions_list = []
        @revision += 1
        self.class.invalidate!
      end
    end

    private

    attr_accessor :type, :permissions_list

    def permissions_list_snapshot
      @mutex.synchronize { permissions_list.dup }
    end
  end
end
