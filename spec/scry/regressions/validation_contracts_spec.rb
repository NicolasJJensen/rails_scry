# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'validation contracts' do
  describe 'invalid_filter_policy :raise mode through filter_records_by' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |cfg|
          original = User.scry_permissions.deep_dup(klass: User)
          begin
            cfg.invalid_filter_policy = :raise
            example.run
          ensure
            User.scry_permissions = original
            User.scry_permissions.clear_caches!
          end
        end
      end
  
      it 'raises FilterError for invalid property name' do
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'nonexistent_column', predicate: 'eq', args: ['x'] }
          ]
        }
        expect {
          Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        }.to raise_error(Scry::FilterError, /invalid property/)
      end
  
      it 'raises FilterError for invalid association name' do
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'nonexistent_assoc', predicate: 'has_any', args: [[1]] }
          ]
        }
        expect {
          Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        }.to raise_error(Scry::FilterError, /invalid or missing association/)
      end
  
      it 'raises FilterError when filter depth is exceeded' do
        Scry.configuration.max_filter_depth = 2
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'group', predicate: 'and', filters: [
              { type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'first_name', predicate: 'eq', args: ['x'] }
              ] }
            ] }
          ]
        }
        expect {
          Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        }.to raise_error(Scry::FilterError, /depth/)
      end
  
      it 'raises FilterError when model is denied' do
        User.add_model_permission { |_ctx| false }
        User.scry_permissions.clear_caches!
        filter = { type: 'group', predicate: 'and', filters: [] }
        expect {
          Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        }.to raise_error(Scry::FilterError, /not allowed/)
      end
    end

  describe 'diagnostic_logging :warn with invalid_filter_policy :skip' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |cfg|
          original = User.scry_permissions.deep_dup(klass: User)
          begin
            cfg.diagnostic_logging = :warn
            cfg.invalid_filter_policy = :skip
            example.run
          ensure
            User.scry_permissions = original
            User.scry_permissions.clear_caches!
          end
        end
      end
  
      it 'logs warning for invalid property and returns nil' do
        expect(Rails.logger).to receive(:warn).with(a_string_including('invalid property'))
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'nonexistent', predicate: 'eq', args: ['x'] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to be_a(ActiveRecord::Relation)
      end
  
      it 'logs warning for denied model and returns empty relation' do
        expect(Rails.logger).to receive(:warn).with(a_string_including('not allowed'))
        User.add_model_permission { |_ctx| false }
        User.scry_permissions.clear_caches!
        filter = { type: 'group', predicate: 'and', filters: [] }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to be_a(ActiveRecord::Relation)
        expect(result).to be_empty
      end
    end

  describe 'missing :predicate key' do
      it 'returns nil when property filter omits :predicate' do
        instance = Scry::Filters::Property.new(
          model: User,
          filter: { property: 'first_name', value: 'x' },
          context: nil
        )
        expect(instance.apply).to be_failed
      end
  
      it 'returns nil when association filter omits :predicate' do
        instance = Scry::Filters::Association.new(
          model: User,
          filter: { association: 'organisation', value: 1 },
          context: nil
        )
        expect(instance.apply).to be_failed
      end
    end

  describe 'missing :type key in group child' do
      it 'skips child filter with nil type' do
        user = create(:user, first_name: 'Alice')
        filter = {
          type: 'group', predicate: 'and', filters: [
            { property: 'first_name', predicate: 'eq', value: 'Alice' },
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(user)
    end

    it 'rejects an unknown explicit root type instead of treating it as a group' do
      result = Scry.filter_records_by(
        records: User,
        filter: { type: 'does_not_exist', predicate: 'and', filters: [] },
        context: nil
      )

      expect(result).to be_failed
      expect(result.diagnostics).to contain_exactly(
        have_attributes(code: :unknown_filter_type, path: [])
      )
    end
  end

  describe 'group with non-array :value' do
      it 'returns nil when group value is a string' do
        filter = { type: 'group', predicate: 'and', filters: 'not_an_array' }
        result = Scry::Filters::Group.new(model: User, filter: filter, context: nil).apply
        expect(result).to be_failed
      end
  
      it 'returns nil when group value is nil' do
        filter = { type: 'group', predicate: 'and', filters: nil }
        result = Scry::Filters::Group.new(model: User, filter: filter, context: nil).apply
        expect(result).to be_failed
      end
    end

  describe 'missing :property key in Property filter' do
      it 'returns nil when property filter omits :property' do
        instance = Scry::Filters::Property.new(
          model: User,
          filter: { predicate: 'eq', value: 'x' },
          context: nil
        )
        expect(instance.apply).to be_failed
      end
    end
end
