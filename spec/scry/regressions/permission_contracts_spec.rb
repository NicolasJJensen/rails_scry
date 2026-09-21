# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'permission contracts' do
  describe 'strict mode predicates' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |cfg|
          cfg.strict = true
          original = User.scry_permissions.deep_dup(klass: User)
          begin
            example.run
          ensure
            User.scry_permissions = original
            User.scry_permissions.clear_caches!
          end
        end
      end
  
      it 'starts with empty predicates in strict mode' do
        User.scry_permissions.clear_caches!
        preds = User.filter_predicate_permissions(nil)
        # All properties should have empty predicates in strict mode without includelist
        preds.each_value do |pred_list|
          expect(pred_list).to be_empty
        end
      end
  
      it 'allows predicates added via includelist in strict mode' do
        User.add_filter_permission(:properties, list_type: :includelist) { [:first_name] }
        User.add_filter_permission(:predicates, list_type: :includelist) { [:eq, :matches] }
        User.scry_permissions.clear_caches!
  
        preds = User.filter_predicate_permissions(nil)
        expect(preds[:first_name]).to include(:eq)
        expect(preds[:first_name]).to include(:matches)
      end
    end

  describe 'custom property filters list_type' do
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
  
      it 'includes custom properties via includelist (default)' do
        User.add_custom_property_filter do |_ctx|
          { full_name: { type: 'group', predicate: 'and', filters: [] } }
        end
        User.scry_permissions.clear_caches!
  
        cpf = User.custom_property_filters(nil)
        expect(cpf).to have_key(:full_name)
      end
  
      it 'removes custom properties via blacklist' do
        User.add_custom_property_filter do |_ctx|
          { full_name: { type: 'group', predicate: 'and', filters: [] },
            display_name: { type: 'group', predicate: 'and', filters: [] } }
        end
        User.add_filter_permission(:custom_property_filters, list_type: :blacklist) do |_ctx|
          { full_name: nil }
        end
        User.scry_permissions.clear_caches!
  
        cpf = User.custom_property_filters(nil)
        expect(cpf).not_to have_key(:full_name)
        expect(cpf).to have_key(:display_name)
      end
  
      it 'keeps only matching keys via whitelist' do
        User.add_custom_property_filter do |_ctx|
          { full_name: { type: 'group', predicate: 'and', filters: [] },
            display_name: { type: 'group', predicate: 'and', filters: [] } }
        end
        User.add_filter_permission(:custom_property_filters, list_type: :whitelist) do |_ctx|
          { display_name: nil }
        end
        User.scry_permissions.clear_caches!
  
        cpf = User.custom_property_filters(nil)
        expect(cpf).not_to have_key(:full_name)
        expect(cpf).to have_key(:display_name)
      end
    end

  describe 'Cache clearing isolation between classes' do
      it 'clearing one model cache does not affect another' do
        user_perms = User.scry_permissions
        email_perms = Email.scry_permissions
  
        # Prime both caches
        user_perms.allowed_properties(nil)
        email_perms.allowed_properties(nil)
  
        # Clear User caches only
        user_perms.clear_caches!
  
        # Email cache should still be warm (same object_id on repeated calls)
        result1 = email_perms.allowed_properties(nil)
        result2 = email_perms.allowed_properties(nil)
        expect(result1.object_id).to eq(result2.object_id)
      end
    end

  describe 'strict: true mode' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |cfg|
          original = User.scry_permissions.deep_dup(klass: User)
          begin
            cfg.strict = true
            User.scry_permissions.clear_caches!
            example.run
          ensure
            User.scry_permissions = original
            User.scry_permissions.clear_caches!
          end
        end
      end
  
      it 'returns empty allowed_properties when no permissions are configured' do
        expect(User.filter_property_permissions(nil)).to be_empty
      end
  
      it 'returns empty allowed_associations when no permissions are configured' do
        expect(User.filter_association_permissions(nil)).to be_empty
      end
  
      it 'includes whitelisted properties in strict mode' do
        User.add_filter_permission(:properties, list_type: :includelist) { |_| [:first_name, :last_name] }
        User.scry_permissions.clear_caches!
        props = User.filter_property_permissions(nil)
        expect(props).to include(:first_name, :last_name)
        expect(props).not_to include(:date_of_birth, :active)
      end
  
      it 'includes whitelisted associations in strict mode' do
        User.add_filter_permission(:associations, list_type: :includelist) { |_| [:organisation] }
        User.scry_permissions.clear_caches!
        assocs = User.filter_association_permissions(nil)
        expect(assocs).to include(:organisation)
      end
    end

  describe 'model_allowed? denial returns empty relation' do
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
  
      it 'returns empty ActiveRecord::Relation when model is denied in ignore mode' do
        create(:user, first_name: 'ShouldNotAppear')
        User.add_model_permission { |_ctx| false }
        User.scry_permissions.clear_caches!
        filter = { type: 'group', predicate: 'and', filters: [] }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to be_a(ActiveRecord::Relation)
        expect(result).to be_empty
      end
    end
end
