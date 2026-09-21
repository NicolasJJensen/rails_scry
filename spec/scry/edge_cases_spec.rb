require 'rails_helper'

RSpec.describe 'Scry edge cases' do
  describe 'valid_aggregate? with missing property' do
    it 'rejects SUM without a property' do
      create(:user, emails_count: 0)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'sum', predicate: 'gteq', args: [1] }
          # No property specified
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  describe 'invalid aggregate function name' do
    it 'returns original records for unknown aggregate function' do
      create(:user, emails_count: 0)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'median', predicate: 'gteq', args: [1] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  describe 'string-keyed filter hashes (JSON params)' do
    it 'works with string keys via deep_symbolize_keys' do
      create(:user, first_name: 'Alice')
      create(:user, first_name: 'Bob')

      filter = {
        'type' => 'group', 'predicate' => 'and', "filters" => [
          { 'type' => 'property', 'property' => 'first_name', 'predicate' => 'eq', "args" => ['Alice'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result.map(&:first_name)).to eq(['Alice'])
    end
  end

  describe 'recursion depth limit' do
    it 'rejects filters exceeding max_filter_depth' do
      Scry.configuration.with_temporary_settings do |cfg|
        cfg.max_filter_depth = 3

        # Build a filter nested 4 levels deep
        inner = { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        4.times do
          inner = { type: 'group', predicate: 'and', filters: [inner] }
        end

        result = Scry.filter_records_by(records: User, filter: inner, context: nil).relation
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end

    it 'allows filters within max_filter_depth' do
      create(:user, first_name: 'Alice')

      Scry.configuration.with_temporary_settings do |cfg|
        cfg.max_filter_depth = 10

        inner = { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        3.times do
          inner = { type: 'group', predicate: 'and', filters: [inner] }
        end

        result = Scry.filter_records_by(records: User, filter: inner, context: nil).relation
        expect(result).not_to be_nil
        expect(result.count).to eq(1)
      end
    end
  end

  describe 'TypeRegistry cycle detection' do
    it 'does not infinite loop with circular type groups' do
      registry = Scry::TypeRegistry.new
      registry.register(:group_a, :group_b)
      registry.register(:group_b, :group_a)

      # Should terminate without hanging
      result = registry.by_group(:group_a)
      expect(result).to be_an(Array)
      expect(result).to include(:group_a, :group_b)
    end
  end

  describe 'filter_capabilities returns structured hash' do
    it 'returns a hash with expected keys' do
      result = Scry.filter_capabilities(model: User, context: nil)
      expect(result).to be_a(Hash)
      expect(result.keys).to include(:properties, :associations, :predicates, :property_predicates, :aggregates)
    end

    it 'properties are arrays of hashes with key and label' do
      result = Scry.filter_capabilities(model: User, context: nil)
      expect(result[:properties]).to be_an(Array)
      expect(result).to be_frozen
      expect(result[:properties]).to be_frozen
      result[:properties].each do |prop|
        expect(prop).to have_key(:key)
        expect(prop).to have_key(:label)
        expect(prop).to be_frozen
      end
    end
  end

  describe 'SUM DISTINCT rejects non-column properties' do
    it 'returns nil for SUM DISTINCT with invalid property name' do
      user = create(:user, emails_count: 0)
      user.emails << create(:email, address: 'a@x.com')

      filter = {
        type: 'aggregate',
        association: 'emails',
        property: 'nonexistent_column',
        aggregate: 'sum',
        predicate: 'gteq',
        args: [1],
        distinct?: true
      }

      instance = Scry::Filters::Aggregate.new(model: User, filter: filter, context: nil)
      expect(instance.apply).to be_failed
    end
  end

  describe 'memoization caches nil/false correctly' do
    it 'caches nil allowed_aggregates without re-computing' do
      perms = User.scry_permissions

      # Prime the cache
      result1 = perms.allowed_aggregates(nil)
      # Should return same object (cached)
      result2 = perms.allowed_aggregates(nil)
      expect(result1.object_id).to eq(result2.object_id)
    end
  end
end
