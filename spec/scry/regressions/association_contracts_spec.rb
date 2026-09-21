# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'association contracts' do
  describe 'Association reflection behavior' do
      it 'filters a belongs_to association through the public API' do
        organisation = create(:organisation)
        user = create(:user, organisation: organisation)
  
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'organisation', predicate: 'has_any', args: [[organisation.id]] }
          ]
        }
  
        result = Scry.filter_records_by(records: User.where(id: user.id), filter: filter, context: nil).relation
  
        expect(result.ids).to eq([user.id])
      end
  
      it 'filters a HABTM association through the public API' do
        email = create(:email)
        user = create(:user, emails_count: 0)
        user.emails << email
  
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'emails', predicate: 'has_any', args: [[email.id]] }
          ]
        }
  
        result = Scry.filter_records_by(records: User.where(id: user.id), filter: filter, context: nil).relation
  
        expect(result.ids).to eq([user.id])
      end
    end

  describe 'Association validator error handling' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |cfg|
          cfg.callback_error_policy = :match_none
          original = User.scry_permissions.deep_dup(klass: User)
          begin
            example.run
          ensure
            User.scry_permissions = original
            User.scry_permissions.clear_caches!
          end
        end
      end
  
      it 'returns an empty relation under the match-none callback policy' do
        # Register a predicate with a failing validator that's valid for associations
        # Must provide arel_predicate so register_predicate doesn't skip it
        Scry.configuration.register_predicate(:failing_assoc_pred,
          types: %i[single_association], applies_to: [:association], compounds: false,
          arel_predicate: :has_any,
          validator: ->(_v) { raise ArgumentError, 'test validator failure' }
        )
        User.add_filter_permission(:predicates, list_type: :includelist) { [:failing_assoc_pred] }
        User.scry_permissions.clear_caches!
  
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'organisation', predicate: 'failing_assoc_pred', args: [1] }
          ]
        }
        expect(Scry.filter_records_by(records: User, filter: filter, context: nil).relation).to be_empty
      end
  
      it 're-raises the validator error under the raise callback policy' do
        Scry.configuration.invalid_filter_policy = :raise
        Scry.configuration.callback_error_policy = :raise
        Scry.configuration.register_predicate(:failing_assoc_pred,
          types: %i[single_association], applies_to: [:association], compounds: false,
          arel_predicate: :has_any,
          validator: ->(_v) { raise ArgumentError, 'test validator failure' }
        )
        User.add_filter_permission(:predicates, list_type: :includelist) { [:failing_assoc_pred] }
        User.scry_permissions.clear_caches!
  
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'organisation', predicate: 'failing_assoc_pred', args: [1] }
          ]
        }
        expect {
          Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        }.to raise_error(ArgumentError, /test validator failure/)
      end
    end

  describe 'Association with predicate missing both arel_predicate and custom_predicate' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |cfg|
          cfg.invalid_filter_policy = :raise
          example.run
        end
      end
  
      it 'raises when predicate has neither arel_predicate nor custom_predicate' do
        # Register a broken predicate with neither arel_predicate nor block
        # We force this by directly manipulating the registry
        Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
          name: :broken_pred,
          arel_predicate: nil,
          custom_predicate: nil,
          formatter: nil,
          validator: nil,
          types: [:single_association],
          applies_to: [:association]
        })
  
        filter = { type: 'association', association: 'organisation', predicate: 'broken_pred', args: [1] }
        # Need to add broken_pred to allowed predicates
        original = User.scry_permissions.deep_dup(klass: User)
        User.add_filter_permission(:predicates, list_type: :includelist) { [:broken_pred] }
        User.scry_permissions.clear_caches!
  
        begin
          public_filter = { type: 'group', predicate: 'and', filters: [filter] }
          expect {
            Scry.filter_records_by(records: User, filter: public_filter, context: nil).relation
          }.to raise_error(Scry::FilterError, /no arel_predicate or custom_predicate/)
        ensure
          User.scry_permissions = original
          User.scry_permissions.clear_caches!
        end
      end
    end

  describe 'aggregates includelist association filtering' do
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
  
      it 'does not add unauthorized associations via includelist' do
        # Blacklist emails association
        User.add_filter_permission(:associations, list_type: :blacklist) { [:emails] }
        # Try to add emails aggregate via includelist
        User.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
          { emails: { count: true } }
        end
        User.scry_permissions.clear_caches!
  
        aggs = User.scry_permissions.allowed_aggregates(nil)
        expect(aggs).not_to have_key('emails')
      end
    end

  describe 'association predicates with empty arrays' do
      it 'has_any with empty array returns no results' do
        user = create(:user, emails_count: 2)
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'emails', predicate: 'has_any', args: [[]] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to be_empty
      end
  
      it 'has_all with empty array returns all results (vacuous truth)' do
        user = create(:user)
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'emails', predicate: 'has_all', args: [[]] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(user)
      end
    end

  describe 'not_has_any association predicate' do
      it 'filters users NOT associated with the given organisation' do
        org1 = create(:organisation)
        org2 = create(:organisation)
        u1 = create(:user, organisation: org1)
        u2 = create(:user, organisation: org2)
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'organisation', predicate: 'not_has_any', args: [[org1.id]] }
          ]
        }
        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u2)
        expect(result).not_to include(u1)
      end
    end
end
