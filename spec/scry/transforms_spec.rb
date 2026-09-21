require 'rails_helper'

RSpec.describe 'Scry property transforms' do
  let(:ctx) { nil }

  around(:each) do |example|
    # Snapshot and restore the model-level filter permissions so tests don't leak changes
    original = User.scry_permissions.deep_dup(klass: User)
    begin
      example.run
    ensure
      User.scry_permissions = original
      User.scry_permissions.clear_caches!
    end
  end

  before(:each) do
    @users_before = User.pluck(:id)
  end

  describe '.add_filter_transform' do
    it 'raises ArgumentError for a property that is not a valid identifier' do
      [nil, 123, 'first name', ''].each do |property|
        expect {
          User.add_filter_transform(property) { |value, _context| value }
        }.to raise_error(ArgumentError, 'property must be a valid identifier')
      end
    end
  end

  after(:each) do
    # Clean up any users created by these examples to avoid leaking state into other specs
    User.where.not(id: @users_before).delete_all
  end

  describe 'defaults: on: [:attribute, :value_node]' do
    it 'applies symmetrical LOWER() to attribute and value for textual predicates' do
      # Configure a symmetric transform for first_name (LOWER on both sides)
      User.add_filter_transform(:first_name) do |node, _ctx|
        Arel::Nodes::NamedFunction.new('LOWER', [node])
      end

      # Allow textual predicates on first_name
      User.add_filter_permission(:property_predicates) do |_ctx|
        { first_name: %i[eq matches starts_with ends_with] }
      end

      u1 = create(:user, first_name: 'Test')
      _u2 = create(:user, first_name: 'Other')

      # Case-insensitive equality via symmetric LOWER
      filter = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'eq', args: ['test'] }
      ] }
      expect(Scry.filter_records_by(records: User, filter: filter, context: ctx).relation).to match_array([u1])

      # Case-insensitive contains (formatter adds %; transform runs after formatter)
      filter2 = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'matches', args: ['EST'] }
      ] }
      expect(Scry.filter_records_by(records: User, filter: filter2, context: ctx).relation).to include(u1)
    end
  end

  describe 'on: :value (pre-formatter)' do
    it 'trims raw value before eq comparison' do
      User.add_filter_transform(:first_name, on: :value) { |v, _ctx| v.to_s.strip }
      User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[eq] } }

      u = create(:user, first_name: 'Alice')

      filter = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'eq', args: ['  Alice  '] }
      ] }

      expect(Scry.filter_records_by(records: User, filter: filter, context: ctx).relation).to match_array([u])
    end
  end

  describe 'matching and precedence' do
    it 'applies predicate-name transforms before type-group transforms, then global, in insertion order' do
      # Track application order by pushing to an array via closures
      applied = []

      # Global (no only): apply last
      User.add_filter_transform(:first_name, on: :attribute) do |node, _ctx|
        applied << :global
        node
      end

      # Type group: textual
      User.add_filter_transform(:first_name, only: [:textual], on: :attribute) do |node, _ctx|
        applied << :type
        node
      end

      # Specific predicate: eq (should run first)
      User.add_filter_transform(:first_name, only: [:eq], on: :attribute) do |node, _ctx|
        applied << :predicate
        node
      end

      User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[eq] } }

      u = create(:user, first_name: 'Bob')
      filter = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'eq', args: ['Bob'] }
      ] }
      _ = Scry.filter_records_by(records: User, filter: filter, context: ctx).relation.to_a

      expect(applied).to eq([:predicate, :type, :global])
      expect(u).to be_present
    end

    it 'supports only OR semantics and except exclusion' do
      User.add_filter_transform(:last_name, only: [:textual], except: [:eq]) do |node, _ctx|
        # Should NOT run for eq, should run for matches
        Arel::Nodes::NamedFunction.new('LOWER', [node])
      end

      User.add_filter_permission(:property_predicates) { |_ctx| { last_name: %i[eq matches] } }

      u = create(:user, last_name: 'Smith')

      # eq should not use LOWER transform; still matches case-sensitively
      f_eq = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'last_name', predicate: 'eq', args: ['Smith'] }
      ] }
      expect(Scry.filter_records_by(records: User, filter: f_eq, context: ctx).relation).to include(u)

      # matches should use LOWER on both sides (default on applies to [:attribute, :value_node])
      f_matches = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'last_name', predicate: 'matches', args: ['SMI'] }
      ] }
      expect(Scry.filter_records_by(records: User, filter: f_matches, context: ctx).relation).to include(u)
    end
  end

  describe 'full 6-step pipeline end-to-end' do
    it 'exercises validator, value transform, formatter, value_node transform, attribute transform, and predicate node' do
      # Track which steps were hit
      steps_hit = []

      # Register a predicate with validator and formatter
      Scry.configuration.with_temporary_settings do |config|
        config.register_predicate(
          :pipeline_test,
          types: [:textual],
          arel_predicate: :eq,
          # Step 1: validator (strips whitespace)
          validator: ->(v) { steps_hit << :validator; v.to_s.strip },
          # Step 3: formatter (downcase)
          formatter: ->(v) { steps_hit << :formatter; v.to_s.downcase }
        )

        # Step 2: value transform (prepend marker)
        User.add_filter_transform(:first_name, only: [:pipeline_test], on: :value) do |v, _ctx|
          steps_hit << :value_transform
          v
        end

        # Step 4: value_node transform (wrap in function)
        User.add_filter_transform(:first_name, only: [:pipeline_test], on: :value_node) do |node, _ctx|
          steps_hit << :value_node_transform
          node
        end

        # Step 5: attribute transform (apply LOWER)
        User.add_filter_transform(:first_name, only: [:pipeline_test], on: :attribute) do |attr, _ctx|
          steps_hit << :attribute_transform
          Arel::Nodes::NamedFunction.new('LOWER', [attr])
        end

        User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[pipeline_test] } }
        User.scry_permissions.clear_caches!

        u = create(:user, first_name: 'Alice')

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'pipeline_test', args: ['  Alice  '] }
        ] }

        result = Scry.filter_records_by(records: User, filter: filter, context: ctx).relation
        # Validator strips to 'Alice', value_transform passes through, formatter lowercases to 'alice',
        # attribute_transform wraps in LOWER, so LOWER(first_name) = 'alice' matches
        expect(result).to include(u)

        # Verify all 5 model-reachable steps fired in order
        # (Step 6 is build_predicate_node which is internal and always fires)
        expect(steps_hit).to eq([:validator, :value_transform, :formatter, :value_node_transform, :attribute_transform])
      end
    end
  end

  describe 'arrays for _any/_all' do
    it 'applies value transforms element-wise' do
      User.add_filter_transform(:first_name, on: :value) { |v, _ctx| v.to_s.downcase }
      User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[matches_any] } }

      u = create(:user, first_name: 'Alice')

      filter = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'matches_any', args: [%w[BOB ALI]] }
      ] }

      expect(Scry.filter_records_by(records: User, filter: filter, context: ctx).relation).to include(u)
    end
  end
end
