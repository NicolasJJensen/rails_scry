# frozen_string_literal: true

module Scry
  module Filterable
    VALID_LIST_TYPES = %i[whitelist blacklist includelist excludelist].freeze

    class NamedCallback
      def initialize(model, method)
        @model = model
        @method = method
        freeze
      end

      def call(*args)
        # Resolve named models at invocation so Rails reloads do not leave this
        # callback using a stale class object.
        model = @model.name ? @model.name.constantize : @model
        model.__send__(@method, *args)
      end

      def for_model(model)
        self.class.new(model, @method)
      end
    end

    extend ActiveSupport::Concern

    included do
      class_attribute :scry_permissions, default: FilterPermissions.new(
        klass: self
      )
      class_attribute :scry_targets, default: {}.freeze
      class_attribute :scry_scopes, default: [].freeze
    end

    class_methods do
      def attribute(...)
        result = super
        FilterPermissionsChain.invalidate!
        result
      end

      def reset_column_information
        result = super
        FilterPermissionsChain.invalidate!
        result
      end

      def table_name=(name)
        super.tap { FilterPermissionsChain.invalidate! }
      end

      def inherited(subclass)
        super
        # Deep dup the hash so it can inherit from the parent classes but changes won't affect the parent or sibling classes
        subclass.scry_permissions = scry_permissions.deep_dup(
          klass: subclass
        )
        subclass.scry_targets = scry_targets.deep_dup.freeze
        subclass.scry_scopes = scry_scopes.map do |callback|
          callback.respond_to?(:for_model) ? callback.for_model(subclass) : callback
        end.freeze
      end

      def reset_filter_permissions(*types)
        scry_permissions.reset_permissions(*types)
      end

      def add_filter_permission(type, function = nil, metadata: nil, **options, &block)
        if type.to_sym == :model && options.key?(:list_type)
          raise ArgumentError, "scry_permissions for :model does not support list_type"
        end

        list_type = options[:list_type] || :includelist
        unless VALID_LIST_TYPES.include?(list_type)
          raise ArgumentError, "scry_permissions for #{type.inspect} was given an invalid options[:list_type] of #{list_type.inspect}. Valid types: #{VALID_LIST_TYPES.inspect}"
        end

        permission = {
          list_type:,
          block: get_block(function, &block)
        }
        permission[:metadata] = metadata if metadata
        scry_permissions[type].add_permission(permission)
        Scry.clear_thread_caches!
      end

      # Declare the allowed concrete targets for a polymorphic association.
      # The map is static and inherited, so client input can resolve only to
      # models selected by the application during boot.
      def add_filter_targets(association, **targets)
        association = association.to_sym
        unless targets.all? { |name, model| name.is_a?(String) || name.is_a?(Symbol) } &&
            targets.values.all? { |model| model.is_a?(Class) && model < ActiveRecord::Base }
          raise ArgumentError, "filter targets must map names to ActiveRecord models"
        end

        updated = scry_targets.deep_dup
        updated[association] = targets.each_with_object({}) do |(name, model), map|
          token = model.respond_to?(:polymorphic_name) ? model.polymorphic_name : name.to_s
          map[name.to_sym] = { model:, token: token.to_s }.freeze
        end.freeze
        self.scry_targets = updated
        FilterPermissionsChain.invalidate!
      end

      def targets_for(association)
        scry_targets[association.to_sym]&.dup&.freeze || {}.freeze
      end

      def target_model(association, token)
        entry = targets_for(association).values.find { |target| target[:token] == token.to_s }
        entry && entry[:model]
      end

      # Register a virtual property filter. Metadata is optional and can be
      # supplied for every property returned by the callable. A callable may
      # also return entries shaped as { filter:, type:, label:, predicates: }
      # when different properties need different metadata.
      def add_custom_property_filter(function = nil, type: nil, label: nil, predicates: nil, metadata: nil, &block)
        metadata = (metadata || {}).dup
        metadata[:type] = type if type
        metadata[:label] = label if label
        metadata[:predicates] = predicates if predicates
        metadata = nil if metadata.empty?
        add_filter_permission(:custom_property_filters, function, metadata:, &block)
      end

      def add_model_permission(function = nil, &block)
        add_filter_permission(:model, function, &block)
      end

      def add_filter_scope(function = nil, &block)
        callback = get_block(function, &block)
        self.scry_scopes = [*scry_scopes, callback].freeze
        Scry.clear_thread_caches!
      end

      def filter_property_permissions(context = nil)
        scry_permissions.allowed_properties(context)
      rescue Scry::CallbackFailure
        Set.new
      end

      def filter_association_permissions(context = nil)
        scry_permissions.allowed_associations(context)
      rescue Scry::CallbackFailure
        Set.new
      end

      def filter_predicate_permissions(context = nil)
        scry_permissions.allowed_property_predicates(context)
      rescue Scry::CallbackFailure
        {}
      end

      def filter_capabilities(context = nil, locale: I18n.locale)
        if self.is_a?(Class) && self < ActiveRecord::Base
          Scry.filter_capabilities(model: self, context: context, locale: locale)
        else
          begin
            scry_permissions.to_h(context, locale: locale)
          rescue Scry::CallbackFailure
            Scry::Immutable.copy(Scry.empty_information.merge(error: true))
          end
        end
      end

      def model_allowed?(context = nil)
        scry_permissions.model_allowed?(context)
      rescue Scry::CallbackFailure
        false
      end

      def custom_property_filters(context = nil)
        scry_permissions.allowed_custom_property_filters(context)
      rescue Scry::CallbackFailure
        {}
      end

      # Define per-property transforms applied during filtering.
      # API:
      #   add_filter_transform(property, function = nil, only: [], except: [], on: [:attribute, :value_node], &block)
      # - property: Symbol or String property name
      # - only: Array of predicate names and/or predicate type groups (OR semantics). Empty means all.
      # - except: Array of predicate names or type groups to exclude (wins over only).
      # - on: one or more of [:attribute, :value, :value_node]. Defaults to [:attribute, :value_node]
      #   which are both Arel node targets. Use :value (raw Ruby value, pre-formatter) only for
      #   transforms that operate on Ruby values (e.g., strip, downcase), not Arel functions.
      # - function or block: one callable; block receives (operand, context) where operand is:
      #     - on: :attribute => Arel attribute/node
      #     - on: :value     => Ruby value (pre-formatter)
      #     - on: :value_node=> Arel quoted node (post-formatter)
      def add_filter_transform(property, function = nil, only: [], except: [], on: [:attribute, :value_node], &block)
        property = validate_transform_property!(property)
        callable = get_block(function, &block)

        on_targets = Array(on).map { |t| t.to_sym }
        unless (on_targets - [:attribute, :value, :value_node]).empty?
          raise ArgumentError, "on must be one or more of [:attribute, :value, :value_node]"
        end

        only_list = Array(only).map(&:to_sym)
        except_list = Array(except).map(&:to_sym)

        scry_permissions[:property_transforms].add_permission({
          list_type: :includelist,
          block: callable,
          property: property,
          only: only_list,
          except: except_list,
          on: on_targets
        })
      end

      private

      def validate_transform_property!(property)
        valid = (property.is_a?(String) || property.is_a?(Symbol)) &&
          property.to_s.match?(Filters::Base::VALID_IDENTIFIER) &&
          property.to_s.length <= Filters::Base::MAX_IDENTIFIER_LENGTH
        return property.to_sym if valid

        raise ArgumentError, 'property must be a valid identifier'
      rescue ArgumentError => error
        raise error if error.message == 'property must be a valid identifier'

        raise ArgumentError, 'property must be a valid identifier'
      end

      def get_block(function = nil, &block)
        if block_given? && function
          raise ArgumentError, 'both a block and a function were given, only one is allowed'
        elsif !block_given? && !function
          raise ArgumentError, 'no block or function was given'
        elsif function
          block = NamedCallback.new(self, function)
        end

        block
      end
    end
  end
end
