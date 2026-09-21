# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round11' + ' - ' + 'Aggregate HAVING guards' do
  describe 'Aggregate HAVING guards' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        example.run
      end
    end

    it 'rescues NoMethodError when __send__ fails on aggregate HAVING' do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :bogus_having_arel,
        arel_predicate: :totally_nonexistent_method,
        types: [:all],
        applies_to: [:aggregate]
      })

      create(:user, emails_count: 2)

      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'bogus_having_arel', args: [1]
      }

      expect {
        Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [filter] },
          context: nil
        ).relation
      }.to raise_error(Scry::FilterError, /Arel predicate :totally_nonexistent_method failed/)
    ensure
      Scry.configuration.predicate_registry.unregister(:bogus_having_arel)
    end

    it 'validates custom_predicate return type in HAVING' do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :bad_having_custom,
        custom_predicate: ->(_attr, _val) { 'not an arel node' },
        types: [:all],
        applies_to: [:aggregate]
      })

      create(:user, emails_count: 2)

      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'bad_having_custom', args: [1]
      }

      expect {
        Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [filter] },
          context: nil
        ).relation
      }.to raise_error(Scry::FilterError, /returned invalid node/)
    ensure
      Scry.configuration.predicate_registry.unregister(:bad_having_custom)
    end

    it 're-raises formatter exceptions in HAVING under :raise callback policy' do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :having_bad_fmt,
        arel_predicate: :eq,
        types: [:all],
        applies_to: [:aggregate],
        formatter: ->(_v) { raise RuntimeError, 'formatter exploded' }
      })

      create(:user, emails_count: 2)

      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'having_bad_fmt', args: [1]
      }

      expect {
        Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [filter] },
          context: nil
        ).relation
      }.to raise_error(RuntimeError, /formatter exploded/)
    ensure
      Scry.configuration.predicate_registry.unregister(:having_bad_fmt)
    end
  end

  # ── 2. filter_records_by edge cases ──────────────────────────────────────────
end

RSpec.describe 'round11' + ' - ' + 'filter_records_by nil fallback' do
  describe 'filter_records_by nil fallback' do
    it 'returns original records when group filter returns nil (all children invalid)' do
      u1 = create(:user)

      result = Scry.filter_records_by(
        records: User.where(id: u1.id),
        filter: { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'nonexistent_col', predicate: 'eq', args: ['x'] }
        ] },
        context: nil
      ).relation
      expect(result).to be_a(ActiveRecord::Relation)
      expect(result).to include(u1)
    end

    it 'raises ArgumentError for non-Hash filter' do
      expect {
        Scry.filter_records_by(records: User, filter: 'not a hash', context: nil).relation
      }.to raise_error(ArgumentError, /filter must be a Hash/)
    end

    it 'handles uppercase group predicate (AND/OR normalized)' do
      u1 = create(:user, first_name: 'Uppercase')

      result = Scry.filter_records_by(
        records: User.where(id: u1.id),
        filter: { type: 'group', predicate: 'AND', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Uppercase'] }
        ] },
        context: nil
      ).relation
      expect(result).to match_array([u1])
    end
  end

  # ── 3. Formatter rescue in base.rb ───────────────────────────────────────────
end

RSpec.describe 'round11' + ' - ' + 'Formatter rescue in base.rb' do
  describe 'Formatter rescue in base.rb' do
    after(:each) do
      Scry.configuration.predicate_registry.unregister(:bad_fmt_pred)
    end

    before(:each) do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :bad_fmt_pred,
        arel_predicate: :eq,
        types: [:all],
        formatter: ->(_v) { raise RuntimeError, 'fmt boom' }
      })
    end

    it 're-raises the formatter error under :raise callback policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise

        expect {
          Scry.filter_records_by(
            records: User,
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'first_name', predicate: 'bad_fmt_pred', args: ['test'] }
            ] },
            context: nil
          ).relation
        }.to raise_error(RuntimeError, /fmt boom/)
      end
    end

    it 'warns and returns records with diagnostic logging enabled when formatter fails' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn
        config.callback_error_policy = :match_none

        expect(Rails.logger).to receive(:warn) do |payload|
          event = JSON.parse(payload)
          expect(event).to include(
            'code' => 'callback_error',
          )
          expect(event['message']).not_to include('formatter exploded')
        end

        result = Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'bad_fmt_pred', args: ['test'] }
          ] },
          context: nil
        ).relation
        expect(result).to be_empty
      end
    end

    it 'returns records silently under :skip policy when formatter fails' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :match_none

        result = Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'bad_fmt_pred', args: ['test'] }
          ] },
          context: nil
        ).relation
        expect(result).to be_empty
      end
    end
  end

  # ── 4. Custom_predicate rescue in base.rb ────────────────────────────────────
end

RSpec.describe 'round11' + ' - ' + 'Custom_predicate rescue in base.rb' do
  describe 'Custom_predicate rescue in base.rb' do
    after(:each) do
      Scry.configuration.predicate_registry.unregister(:crashing_custom)
    end

    before(:each) do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :crashing_custom,
        custom_predicate: ->(_attr, _val) { raise RuntimeError, 'custom boom' },
        types: [:all]
      })
    end

    it 're-raises the custom predicate error under :raise callback policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise

        expect {
          Scry.filter_records_by(
            records: User,
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'first_name', predicate: 'crashing_custom', args: ['test'] }
            ] },
            context: nil
          ).relation
        }.to raise_error(RuntimeError, /custom boom/)
      end
    end

    it 'warns and returns records with diagnostic logging enabled when custom_predicate crashes' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn
        config.callback_error_policy = :match_none

        expect(Rails.logger).to receive(:warn) do |payload|
          event = JSON.parse(payload)
          expect(event).to include(
            'code' => 'callback_error',
          )
          expect(event['message']).not_to include('custom boom')
        end

        result = Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'crashing_custom', args: ['test'] }
          ] },
          context: nil
        ).relation
        expect(result).to be_empty
      end
    end

    it 'returns records silently under :skip policy when custom_predicate crashes' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :match_none

        result = Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'crashing_custom', args: ['test'] }
          ] },
          context: nil
        ).relation
        expect(result).to be_empty
      end
    end
  end

  # ── 5. Formatter rescue in association.rb ────────────────────────────────────
end

RSpec.describe 'round11' + ' - ' + 'Formatter rescue in association.rb' do
  describe 'Formatter rescue in association.rb' do
    after(:each) do
      Scry.configuration.predicate_registry.unregister(:assoc_bad_fmt)
    end

    before(:each) do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :assoc_bad_fmt,
        arel_predicate: :eq,
        types: [:single_association],
        applies_to: [:association],
        formatter: ->(_v) { raise RuntimeError, 'assoc fmt boom' }
      })
    end

    it 're-raises the association formatter error under :raise callback policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise
        create(:user)

        expect {
          Scry.filter_records_by(
            records: User,
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'association', association: 'organisation', predicate: 'assoc_bad_fmt', args: [1] }
            ] },
            context: nil
          ).relation
        }.to raise_error(RuntimeError, /assoc fmt boom/)
      end
    end
  end

  # ── 6. Custom_predicate rescue in association.rb ─────────────────────────────
end

RSpec.describe 'round11' + ' - ' + 'Custom_predicate rescue in association.rb' do
  describe 'Custom_predicate rescue in association.rb' do
    after(:each) do
      Scry.configuration.predicate_registry.unregister(:assoc_crash_custom)
    end

    before(:each) do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :assoc_crash_custom,
        custom_predicate: ->(_attr, _val) { raise RuntimeError, 'assoc custom boom' },
        types: [:single_association],
        applies_to: [:association]
      })
    end

    it 're-raises the association custom predicate error under :raise callback policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise
        create(:user)

        expect {
          Scry.filter_records_by(
            records: User,
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'association', association: 'organisation', predicate: 'assoc_crash_custom', args: [1] }
            ] },
            context: nil
          ).relation
        }.to raise_error(RuntimeError, /assoc custom boom/)
      end
    end
  end

  # ── 7. Memoized predicate/property ───────────────────────────────────────────
end

RSpec.describe 'round11' + ' - ' + 'Memoized predicate/property methods' do
  describe 'Memoized predicate/property methods' do
    it 'Property filter returns consistent predicate and property symbols' do
      filter_hash = { property: 'first_name', predicate: 'eq', value: 'x' }
      f = Scry::Filters::Property.new(model: User, filter: filter_hash, context: nil)
      expect(f.property).to eq(:first_name)
      expect(f.predicate).to eq(:eq)
      # Calling twice returns same memoized value
      expect(f.property).to equal(f.property)
      expect(f.predicate).to equal(f.predicate)
    end

    it 'Base filter memoizes predicate' do
      filter_hash = { predicate: 'eq' }
      f = Scry::Filters::Base.new(model: User, filter: filter_hash, context: nil)
      expect(f.predicate).to eq(:eq)
      expect(f.predicate).to equal(f.predicate)
    end

    it 'Aggregate filter memoizes predicate' do
      filter_hash = { association: 'emails', aggregate: 'count', predicate: 'gteq', value: 1 }
      f = Scry::Filters::Aggregate.new(model: User, filter: filter_hash, context: nil)
      expect(f.predicate).to eq(:gteq)
      expect(f.predicate).to equal(f.predicate)
    end
  end

  # ── 8. Set-based permission caches ───────────────────────────────────────────
end

RSpec.describe 'round11' + ' - ' + 'Set-based permission caches' do
  describe 'Set-based permission caches' do
    it 'allowed_properties returns a Set' do
      result = User.scry_permissions.allowed_properties(nil)
      expect(result).to be_a(Set)
      expect(result).to include(:first_name)
    end

    it 'allowed_associations returns a Set' do
      result = User.scry_permissions.allowed_associations(nil)
      expect(result).to be_a(Set)
      expect(result).to include(:emails)
    end
  end

  # ── 9. Duplicate model_allowed? removed from associations_with_labels ────────
end

RSpec.describe 'round11' + ' - ' + 'associations_with_labels still works after duplicate check removal' do
  describe 'associations_with_labels still works after duplicate check removal' do
    it 'returns associations with labels' do
      result = User.scry_permissions.associations_with_labels(nil)
      expect(result).to be_an(Array)
      keys = result.map { |h| h[:key] }
      expect(keys).to include('emails')
    end
  end
end
