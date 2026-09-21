# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'predicate contracts' do
  describe 'Negation with BOOLEAN_TYPE constant' do
      it 'correctly negates property filters' do
        u1 = create(:user, first_name: 'Alpha')
        u2 = create(:user, first_name: 'Beta')
  
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alpha'], negate: true }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u2)
        expect(result).not_to include(u1)
      end
  
      it 'handles string negate values' do
        u1 = create(:user, first_name: 'Alpha')
        _u2 = create(:user, first_name: 'Beta')
  
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alpha'], negate: 'false' }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u1)
      end
    end

  describe 'Base @scope normalization' do
      it 'normalizes @scope to a Relation when a Class is passed' do
        filter = { type: 'property', property: 'first_name', predicate: 'eq', args: ['test'] }
        instance = Scry::Filters::Property.new(model: User, filter: filter, context: nil)
        scope = instance.instance_variable_get(:@scope)
        expect(scope).to be_a(ActiveRecord::Relation)
      end
  
      it 'preserves existing Relation scope' do
        filter = { type: 'property', property: 'first_name', predicate: 'eq', args: ['test'] }
        relation = User.where(last_name: 'Smith')
        instance = Scry::Filters::Property.new(model: relation, filter: filter, context: nil)
        scope = instance.instance_variable_get(:@scope)
        expect(scope).to be_a(ActiveRecord::Relation)
        expect(scope.where_clause.ast).to be_present
      end
    end

  describe 'negate boolean coercion edge cases' do
      it 'treats negate: "true" (string) as true' do
        u1 = create(:user, first_name: 'Alpha')
        u2 = create(:user, first_name: 'Beta')
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alpha'], negate: 'true' }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u2)
        expect(result).not_to include(u1)
      end
  
      it 'treats negate: 1 (integer) as true' do
        u1 = create(:user, first_name: 'Alpha')
        u2 = create(:user, first_name: 'Beta')
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alpha'], negate: 1 }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u2)
        expect(result).not_to include(u1)
      end
  
      it 'treats negate: "0" (string zero) as false (no negation)' do
        u1 = create(:user, first_name: 'Alpha')
        _u2 = create(:user, first_name: 'Beta')
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alpha'], negate: '0' }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u1)
      end
  
      it 'treats negate: 0 (integer zero) as false (no negation)' do
        u1 = create(:user, first_name: 'Alpha')
        _u2 = create(:user, first_name: 'Beta')
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alpha'], negate: 0 }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u1)
      end
    end

  describe 'between predicate validator' do
      it 'returns nil for between with too few values' do
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'id', predicate: 'between', args: [1] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to be_a(ActiveRecord::Relation)
      end
  
      it 'returns nil for between with too many values' do
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'id', predicate: 'between', args: [1, 2, 3] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end

  describe 'temporal predicates' do
      it 'within filters records created within the duration from now' do
        Timecop.freeze(Time.utc(2025, 6, 15, 12, 0, 0)) do
          old_user = nil
          Timecop.travel(30.hours.ago) { old_user = create(:user, first_name: 'Old') }
          recent_user = create(:user, first_name: 'Recent')
  
          filter = {
            type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'created_at', predicate: 'within', args: ['PT2H'] }
            ]
          }
          result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
          expect(result).to include(recent_user)
          expect(result).not_to include(old_user)
        end
      end
  
      it 'within_previous filters records created in the past duration' do
        Timecop.freeze(Time.utc(2025, 6, 15, 12, 0, 0)) do
          old_user = nil
          Timecop.travel(30.hours.ago) { old_user = create(:user, first_name: 'Old') }
          recent_user = create(:user, first_name: 'Recent')
  
          filter = {
            type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'created_at', predicate: 'within_previous', args: ['PT2H'] }
            ]
          }
          result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
          expect(result).to include(recent_user)
          expect(result).not_to include(old_user)
        end
      end
  
      it 'not_within_previous filters records outside the past duration' do
        Timecop.freeze(Time.utc(2025, 6, 15, 12, 0, 0)) do
          old_user = nil
          Timecop.travel(30.hours.ago) { old_user = create(:user, first_name: 'Old') }
          _recent_user = create(:user, first_name: 'Recent')
  
          filter = {
            type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'created_at', predicate: 'not_within_previous', args: ['PT2H'] }
            ]
          }
          result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
          expect(result).to include(old_user)
        end
      end
    end

  describe 'eq_nil and not_eq_nil predicates' do
      it 'eq_nil matches records with nil last_name' do
        u_nil = create(:user, last_name: nil)
        u_present = create(:user, last_name: 'Smith')
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'last_name', predicate: 'eq_nil', args: [] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u_nil)
        expect(result).not_to include(u_present)
      end
  
      it 'not_eq_nil matches records with non-nil last_name' do
        u_nil = create(:user, last_name: nil)
        u_present = create(:user, last_name: 'Smith')
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'last_name', predicate: 'not_eq_nil', args: [] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u_present)
        expect(result).not_to include(u_nil)
      end
    end

  describe 'not_between property predicate' do
      it 'excludes records within the range' do
        u1 = create(:user)
        u2 = create(:user)
        u3 = create(:user)
        ids = [u1.id, u2.id, u3.id].sort
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'id', predicate: 'not_between', args: [ids[0], ids[1]] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(User.find(ids[2]))
        expect(result).not_to include(User.find(ids[0]))
        expect(result).not_to include(User.find(ids[1]))
      end
    end
end
