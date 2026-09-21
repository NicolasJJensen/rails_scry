require 'rails_helper'

RSpec.describe Scry::Filters::Property do
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

  describe '#apply' do
    context 'with custom_property' do
      it 'expands to Filters::Group for the configured custom property' do
        # Add a custom property :first_name_starts_with_k that matches first_name starting with 'K'
        User.add_custom_property_filter(type: :boolean) do
          {
            first_name_starts_with_k: {
              type: 'group',
              predicate: 'and',
              filters: [
                { type: 'property', property: 'first_name', predicate: 'starts_with', args: ['K'] }
              ]
            }
          }
        end
        User.scry_permissions.clear_caches!

        u1 = create(:user, first_name: 'Kira')
        _u2 = create(:user, first_name: 'Moe')

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name_starts_with_k', predicate: 'eq_true' }
        ] }

        result = Scry.filter_records_by(records: User, filter:, context: nil).relation
        expect(result).to match_array([u1])
      end
    end

    context 'with invalid property' do
      it 'logs a warning and returns nil' do
        create(:user)
        instance = described_class.new(model: User, filter: { property: 'does_not_exist', predicate: 'eq', value: 'x' }, context: nil)
        expect(instance.apply).to be_failed
      end
    end

    context 'with invalid predicate for property' do
      it 'logs a warning and returns nil' do
        create(:user, first_name: 'Amy')
        instance = described_class.new(model: User, filter: { property: 'first_name', predicate: 'not_a_predicate', value: 'x' }, context: nil)
        expect(instance.apply).to be_failed
      end
    end
  end

  describe '#run_predicate (via base)' do
    it 'looks up predicate via predicate_registry.by_name' do
      u = create(:user, first_name: 'Zed')
      filter = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'eq', args: ['Zed'] }
      ] }
      expect(Scry.filter_records_by(records: User, filter:, context: nil).relation).to match_array([u])
    end
  end
end
