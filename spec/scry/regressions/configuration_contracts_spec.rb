# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'configuration contracts' do
  describe 'Configuration#invalid_filter_policy= validation' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings { |_cfg| example.run }
      end
  
      it 'accepts valid symbol values' do
        %i[skip raise match_none].each do |mode|
          expect { Scry.configuration.invalid_filter_policy = mode }.not_to raise_error
          expect(Scry.configuration.invalid_filter_policy).to eq(mode)
        end
      end
  
      it 'converts string values to symbols' do
        Scry.configuration.invalid_filter_policy = 'match_none'
        expect(Scry.configuration.invalid_filter_policy).to eq(:match_none)
      end
  
      it 'rejects invalid values' do
        expect { Scry.configuration.invalid_filter_policy = :log }.to raise_error(ArgumentError, /invalid_filter_policy/)
        expect { Scry.configuration.invalid_filter_policy = 'invalid' }.to raise_error(ArgumentError)
      end
    end

  describe 'Configuration#max_filter_depth= validation' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings { |_cfg| example.run }
      end
  
      it 'accepts valid positive integers' do
        Scry.configuration.max_filter_depth = 1
        expect(Scry.configuration.max_filter_depth).to eq(1)
        Scry.configuration.max_filter_depth = 100
        expect(Scry.configuration.max_filter_depth).to eq(100)
      end
  
      it 'converts string integers' do
        Scry.configuration.max_filter_depth = '10'
        expect(Scry.configuration.max_filter_depth).to eq(10)
      end
  
      it 'rejects zero' do
        expect { Scry.configuration.max_filter_depth = 0 }.to raise_error(ArgumentError, />= 1/)
      end
  
      it 'rejects negative values' do
        expect { Scry.configuration.max_filter_depth = -5 }.to raise_error(ArgumentError, />= 1/)
      end
    end

  describe 'Custom block predicate compound variants' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings { |_cfg| example.run }
      end
  
      it 'registers compound variants for custom block predicates' do
        Scry.configuration.register_predicate(:test_custom, types: [:textual], compounds: true) do |attr, v|
          attr.eq(v)
        end
  
        pr = Scry.configuration.predicate_registry
        expect(pr.by_name(:test_custom)).to be_present
        expect(pr.by_name(:test_custom_any)).to be_present
        expect(pr.by_name(:test_custom_all)).to be_present
      end

      it 'defaults compounds to false' do
        Scry.configuration.register_predicate(:test_default, types: [:textual]) { |attr, v| attr.eq(v) }
        expect(Scry.configuration.predicate_registry.by_name(:test_default_any)).to be_nil
      end

      it 'fails before changing an existing definition when registration is invalid' do
        Scry.configuration.register_predicate(:test_atomic, types: [:textual], arel_predicate: :eq)
        expect { Scry.configuration.register_predicate(:test_atomic, types: [:boolean], arel_predicate: :missing_arel) }
          .to raise_error(ArgumentError, /unknown Arel predicate/)
        expect(Scry.configuration.predicate_registry.by_name(:test_atomic)[:types]).to eq([:textual])
      end

      it 'rejects ambiguous and incomplete registrations' do
        expect { Scry.configuration.register_predicate(:test_missing, types: [:textual]) }.to raise_error(ArgumentError)
        expect { Scry.configuration.register_predicate(:test_ambiguous, arel_predicate: :eq) { |attr, v| attr.eq(v) } }
          .to raise_error(ArgumentError, /both/)
      end
  
      it 'registers compound variants for arel_predicate predicates' do
        Scry.configuration.register_predicate(:test_arel, types: [:textual], compounds: true, arel_predicate: :eq)
        pr = Scry.configuration.predicate_registry
        expect(pr.by_name(:test_arel)).to be_present
        expect(pr.by_name(:test_arel_any)).to be_present
        expect(pr.by_name(:test_arel_all)).to be_present
      end
  
      it 'skips compounds entirely when compounds: false' do
        Scry.configuration.register_predicate(:test_no_compounds, types: [:textual], compounds: false) do |attr, v|
          attr.eq(v)
        end
  
        pr = Scry.configuration.predicate_registry
        expect(pr.by_name(:test_no_compounds)).to be_present
        expect(pr.by_name(:test_no_compounds_any)).to be_nil
        expect(pr.by_name(:test_no_compounds_all)).to be_nil
      end
    end

  describe 'locked settings and reloadable registrations' do
      it 'rejects setting changes after locking but allows registry registration' do
        Scry.configuration.with_temporary_settings do |settings|
          settings.lock_settings!

          expect { settings.invalid_filter_policy = :raise }
            .to raise_error(Scry::FilterError, /settings are locked/)
          expect {
            settings.register_predicate(
              :reloadable_contract_predicate, types: [:textual], compounds: false,
              arel_predicate: :eq
            )
          }.not_to raise_error
          expect(settings.predicate_registry.by_name(:reloadable_contract_predicate)).to be_present
        end
      end
    end
end
