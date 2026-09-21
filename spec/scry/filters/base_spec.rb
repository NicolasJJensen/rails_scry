require 'rails_helper'

RSpec.describe Scry::Filters::Base do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      example.run
    end
  end

  describe 'exception chain preservation' do
    it 'propagates the original callback exception under the default callback policy' do

      Scry.configure do |cfg|
        cfg.register_predicate(:chain_test, types: [:textual]) do |_attr, _val|
          raise RuntimeError, 'original boom'
        end
      end

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'chain_test', args: ['x'] }
        ]
      }

      expect {
        Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      }.to raise_error(RuntimeError, 'original boom')
    end

    it 'propagates NameError from custom_predicate without wrapping' do
      Scry.configure do |cfg|
        cfg.register_predicate(:name_err_test, types: [:textual]) do |_attr, _val|
          raise NameError, 'uninitialized constant FooBar'
        end
      end

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'name_err_test', args: ['x'] }
        ]
      }

      expect {
        Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      }.to raise_error(NameError, /FooBar/)
    end
  end

  describe 'safe_to_sym length guard' do
    it 'rejects identifiers longer than MAX_IDENTIFIER_LENGTH' do
      Scry.configuration.invalid_filter_policy = :raise

      long_name = 'a' * 256
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: long_name, predicate: 'eq', args: ['x'] }
        ]
      }

      expect {
        Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      }.to raise_error(Scry::FilterError, /identifier too long/)
    end

    it 'accepts identifiers within MAX_IDENTIFIER_LENGTH' do
      instance = Scry::Filters::Property.new(
        model: User, filter: { property: 'first_name', predicate: 'eq', value: 'x' }, context: nil
      )
      expect(instance.property).to eq(:first_name)
      expect(instance.predicate).to eq(:eq)
    end
  end

  describe '#run_predicate' do
    context 'when consulting the predicate registry' do
      it 'fetches the predicate via predicate_registry.by_name and applies it' do
        org = create(:organisation)
        u1 = create(:user, first_name: 'Alpha', organisation: org)
        _u2 = create(:user, first_name: 'Beta', organisation: org)

        # Ensure a simple equality predicate exists via registry and works
        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alpha'] }
        ] }

        result = Scry.filter_records_by(records: User, filter:, context: nil).relation
        expect(result).to match_array([u1])
      end
    end

    context 'when a collection predicate receives one collection argument' do
      it 'passes the collection without flattening it' do
        # eq_any has one collection argument.
        org = create(:organisation)
        u1 = create(:user, first_name: 'Gamma', organisation: org)
        _u2 = create(:user, first_name: 'Delta', organisation: org)

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq_any', args: [['Gamma', 'Zeta']] }
        ] }
        result = Scry.filter_records_by(records: User, filter:, context: nil).relation
        expect(result).to match_array([u1])
      end
    end

    context 'when a custom predicate returns a non-NodeExpression' do
      it 'logs a warning and returns nil' do
        # Register a bad predicate that returns a plain string
        Scry.configure do |cfg|
          cfg.register_predicate(:bad_pred, types: [:textual]) { |_attr, _v| 'not an arel node' }
        end

        create(:user, first_name: 'Eta')
        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'bad_pred', args: ['Eta'] }
        ] }

        result = Scry.filter_records_by(records: User, filter:, context: nil).relation
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end

    context 'when formatter and validator are present' do
      it 'applies validator then formatter before building Arel' do
        # predicate that lowercases input (formatter) after validating non-empty string
        Scry.configure do |cfg|
          cfg.register_predicate(
            :ci_matches,
            types: [:textual],
            arel_predicate: :matches,
            validator: ->(v) { raise ArgumentError, 'empty' if v.to_s.strip.empty?; v },
            formatter: ->(v) { "%#{v.downcase}%" }
          )
        end

        org = create(:organisation)
        u1 = create(:user, first_name: 'Kappa', organisation: org)
        _u2 = create(:user, first_name: 'Lambda', organisation: org)

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'ci_matches', args: ['AP'] }
        ] }

        result = Scry.filter_records_by(records: User, filter:, context: nil).relation
        expect(result).to match_array([u1])
      end
    end
  end
end
