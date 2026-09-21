# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round15' + ' - ' + 'Filterable.add_filter_transform invalid on: target' do
  describe 'Filterable.add_filter_transform invalid on: target' do
    it 'raises ArgumentError for invalid on: target' do
      expect {
        User.add_filter_transform(:first_name, on: :bogus) { |n, _| n }
      }.to raise_error(ArgumentError, /on must be one or more of/)
    end
  end

  # ── T15-2: add_filter_permission invalid list_type ───────────────────────────
end

RSpec.describe 'round15' + ' - ' + 'Filterable.add_filter_permission invalid list_type' do
  describe 'Filterable.add_filter_permission invalid list_type' do
    it 'raises ArgumentError for invalid list_type' do
      expect {
        User.add_filter_permission(:properties, list_type: :totally_invalid) { |_ctx| [:first_name] }
      }.to raise_error(ArgumentError, /invalid options\[:list_type\]/)
    end
  end

  # ── T15-4: I18n translate_association lookup ─────────────────────────────────
end

RSpec.describe 'round15' + ' - ' + 'translate_association I18n lookup' do
  describe 'translate_association I18n lookup' do
    it 'uses I18n translation when available' do
      i18n_key = "activerecord.associations.#{User.model_name.i18n_key}.emails"
      I18n.backend.store_translations(:en, {
        activerecord: { associations: { User.model_name.i18n_key.to_sym => { emails: 'Electronic Mail' } } }
      })

      result = User.scry_permissions.associations_with_labels(nil)
      emails_entry = result.find { |h| h[:key] == 'emails' }
      expect(emails_entry[:label]).to eq('Electronic Mail')
    ensure
      # Clean up the I18n translation
      I18n.backend.reload!
    end
  end

  # ── T15-5: filter_capabilities non-Filterable model ───────────────────────────
end

RSpec.describe 'round15' + ' - ' + 'Scry.filter_capabilities non-Filterable model' do
  describe 'Scry.filter_capabilities non-Filterable model' do
    it 'returns a valid hash for a model without Filterable' do
      # Create a temporary class that looks like an AR model but lacks Filterable
      stub_model = Class.new do
        def self.name; 'StubModel'; end
        def self.columns; []; end
        def self.reflect_on_all_associations; []; end
        def self.column_names; []; end
        def self.primary_key; 'id'; end
        def self.model_name; ActiveModel::Name.new(self, nil, 'StubModel'); end
      end

      result = Scry.filter_capabilities(model: stub_model)
      expect(result).to be_a(Hash)
      expect(result).to have_key(:properties)
      expect(result).to have_key(:associations)
    end
  end

  # ── T15-7: Multiple model permission warning ─────────────────────────────────
end

RSpec.describe 'round15' + ' - ' + 'FilterPermissionsChain multiple model permission warning' do
  describe 'FilterPermissionsChain multiple model permission warning' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |_cfg|
        original = User.scry_permissions.deep_dup(klass: User)
        begin
          example.run
        ensure
          User.scry_permissions = original
          User.scry_permissions.clear_caches!
        end
      end
    end

    it 'warns when multiple model permissions are added' do
      User.add_model_permission { |_ctx| true }

      expect(Rails.logger).to receive(:warn).with(/multiple :model permissions/)

      User.add_model_permission { |_ctx| false }
    end
  end

  # ── T15-8: validate_model_filterable non-Filterable branch ───────────────────
end

RSpec.describe 'round15' + ' - ' + 'validate_model_filterable with non-Filterable model' do
  describe 'validate_model_filterable with non-Filterable model' do
    it 'handles association to non-Filterable model gracefully' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn

        user = create(:user)

        # Create a class that doesn't include Filterable
        non_filterable = Class.new do
          def self.name; 'NonFilterable'; end
        end

        real_reflection = User.reflect_on_association(:organisation)
        bad_reflection = double('bad_reflection',
          name: real_reflection.name,
          macro: real_reflection.macro,
          foreign_key: real_reflection.foreign_key
        )
        allow(bad_reflection).to receive(:klass).and_return(non_filterable)
        allow(User).to receive(:reflect_on_association).and_call_original
        allow(User).to receive(:reflect_on_association).with('organisation').and_return(bad_reflection)

        expect(Rails.logger).to receive(:warn).with(/does not include Filterable/)

        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'organisation', predicate: 'has_any', args: [[1]] }
          ]
        }

        result = Scry.filter_records_by(
          records: User.where(id: user.id), filter: filter, context: nil
        ).relation
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end
  end

  # ── T15-9: predicates_by_property whitelist/blacklist/excludelist ─────────────
end

RSpec.describe 'round15' + ' - ' + 'predicates_by_property with different list_types' do
  describe 'predicates_by_property with different list_types' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |_cfg|
        original = User.scry_permissions.deep_dup(klass: User)
        begin
          example.run
        ensure
          User.scry_permissions = original
          User.scry_permissions.clear_caches!
        end
      end
    end

    it 'whitelist restricts predicates to intersection' do
      User.add_filter_permission(:property_predicates, list_type: :whitelist) do |_ctx|
        { first_name: [:eq] }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.__send__(:predicates_by_property, nil)
      expect(preds[:first_name]).to include(:eq)
      expect(preds[:first_name]).not_to include(:matches)
    end

    it 'blacklist removes specified predicates' do
      User.add_filter_permission(:property_predicates, list_type: :blacklist) do |_ctx|
        { first_name: [:eq] }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.__send__(:predicates_by_property, nil)
      expect(preds[:first_name]).not_to include(:eq)
      expect(preds[:first_name]).to include(:matches)
    end

    it 'excludelist removes specified predicates' do
      User.add_filter_permission(:property_predicates, list_type: :excludelist) do |_ctx|
        { first_name: [:matches] }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.__send__(:predicates_by_property, nil)
      expect(preds[:first_name]).not_to include(:matches)
      expect(preds[:first_name]).to include(:eq)
    end
  end

  # ── T15-10: Association filter with nil value ────────────────────────────────
end

RSpec.describe 'round15' + ' - ' + 'Association filter with nil value' do
  describe 'Association filter with nil value' do
    it 'handles association filter with no value or scoping' do
      user = create(:user)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'organisation', predicate: 'has_any' }
        ]
      }

      result = Scry.filter_records_by(
        records: User.where(id: user.id), filter: filter, context: nil
      ).relation
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end
end
