# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round18' + ' - ' + 'Temporal predications' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
      end
    end
  end

  # ── T18-1: Temporal predications ─────────────────────────────────────────────

  describe 'Temporal predications' do
    it 'within returns records created within the duration window' do
      recent = create(:user, created_at: 12.hours.ago)
      old = create(:user, created_at: 3.days.ago)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'created_at', predicate: 'within', args: ['P1D'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(recent)
      expect(result).not_to include(old)
    end

    it 'within_previous returns records from past duration' do
      recent = create(:user, created_at: 2.days.ago)
      old = create(:user, created_at: 10.days.ago)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'created_at', predicate: 'within_previous', args: ['P7D'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(recent)
      expect(result).not_to include(old)
    end

    it 'within_next returns records within next duration' do
      Timecop.freeze(Time.zone.now) do
        future = create(:user, date_of_birth: 12.hours.from_now.to_date)
        past = create(:user, date_of_birth: 3.days.ago.to_date)

        User.add_filter_permission(:property_predicates) { |_ctx| { date_of_birth: %i[within_next] } }
        User.scry_permissions.clear_caches!

        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'date_of_birth', predicate: 'within_next', args: ['P2D'] }
          ]
        }

        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(future)
        expect(result).not_to include(past)
      end
    end

    it 'not_within excludes records within the duration window' do
      recent = create(:user, created_at: 12.hours.ago)
      old = create(:user, created_at: 3.days.ago)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'created_at', predicate: 'not_within', args: ['P1D'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).not_to include(recent)
      expect(result).to include(old)
    end

    it 'returns nil for invalid temporal value type' do
      create(:user)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'created_at', predicate: 'within', args: [12345] }
        ]
      }

      # Default invalid_filter_policy is :skip, validator raises ArgumentError → returns nil → group returns all
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result.count).to eq(User.count)
    end
  end

  # ── T18-3: Global predications (eq_nil / not_eq_nil) ─────────────────────────
end

RSpec.describe 'round18' + ' - ' + 'Global predications' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
      end
    end
  end

  # ── T18-1: Temporal predications ─────────────────────────────────────────────

  describe 'Global predications' do
    it 'eq_nil returns records with NULL column value' do
      u_nil = create(:user, date_of_birth: nil)
      u_set = create(:user, date_of_birth: Date.new(1990, 1, 1))

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'date_of_birth', predicate: 'eq_nil', args: [] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(u_nil)
      expect(result).not_to include(u_set)
    end

    it 'not_eq_nil returns records with non-NULL column value' do
      u_nil = create(:user, date_of_birth: nil)
      u_set = create(:user, date_of_birth: Date.new(1990, 1, 1))

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'date_of_birth', predicate: 'not_eq_nil', args: [] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(u_set)
      expect(result).not_to include(u_nil)
    end
  end

  # ── T18-8+9: Configuration edge cases ───────────────────────────────────────
end

RSpec.describe 'round18' + ' - ' + 'Configuration edge cases' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
      end
    end
  end

  # ── T18-1: Temporal predications ─────────────────────────────────────────────

  describe 'Configuration edge cases' do
    it 'register_predicate with compounds: false and custom block skips _any/_all variants' do
      Scry.configuration.register_predicate(
        :custom_no_compound, types: [:all], compounds: false
      ) { |attr, value| attr.eq(value) }

      registry = Scry.configuration.predicate_registry
      expect(registry.by_name(:custom_no_compound)).to be_present
      expect(registry.by_name(:custom_no_compound_any)).to be_nil
      expect(registry.by_name(:custom_no_compound_all)).to be_nil
    end

    it 'register_predicate with no arel_predicate, no block, invalid name fails' do
      expect {
        Scry.configuration.register_predicate(:totally_fake_not_on_arel, types: [:all])
      }.to raise_error(ArgumentError, /unknown Arel predicate/)
    end
  end

  # ── T18-10+11: Registry cache invalidation ─────────────────────────────────
end

RSpec.describe 'round18' + ' - ' + 'Registry cache invalidation' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
      end
    end
  end

  # ── T18-1: Temporal predications ─────────────────────────────────────────────

  describe 'Registry cache invalidation' do
    it 'BaseRegistry: by_type updates after unregister' do
      registry = Scry.configuration.predicate_registry

      # Cache the :numerical type list (by_type returns an array of name symbols)
      numerical_before = registry.by_type(:numerical)
      expect(numerical_before).to include(:gt)

      # Unregister :gt
      registry.unregister(:gt)

      # by_type should reflect the removal
      numerical_after = registry.by_type(:numerical)
      expect(numerical_after).not_to include(:gt)

      # Re-register to restore state
      Scry.configuration.register_predicate(:gt, compounds: false, types: %i[numerical])
    end

    it 'TypeRegistry: unregister removes from top-level AND from other groups' do
      type_registry = Scry.configuration.predicate_registry.type_registry

      # Register a custom group with a child type
      type_registry.register(:custom_test_group, :child_test_type)
      # Also register :child_test_type into :numerical
      type_registry.register(:numerical, :child_test_type)

      # Verify setup
      expect(type_registry.by_group(:custom_test_group)).to include(:child_test_type)

      # Unregister :child_test_type
      type_registry.unregister(:child_test_type)

      # Should be removed from custom_test_group's member list
      # custom_test_group still exists as a key but :child_test_type is gone from its values
      raw_groups = type_registry.instance_variable_get(:@by_group)
      if raw_groups.key?(:custom_test_group)
        expect(raw_groups[:custom_test_group]).not_to include(:child_test_type)
      end
      # Should also be removed from :numerical's member list
      expect(raw_groups[:numerical]).not_to include(:child_test_type)

      # Clean up
      type_registry.unregister(:custom_test_group)
    end
  end

  # ── T18-12: Group with empty value array ────────────────────────────────────
end

RSpec.describe 'round18' + ' - ' + 'Group with empty value array' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
      end
    end
  end

  # ── T18-1: Temporal predications ─────────────────────────────────────────────

  describe 'Group with empty value array' do
    it 'returns all records when group has no children' do
      u1 = create(:user)
      u2 = create(:user)

      filter = { type: 'group', predicate: 'and', filters: [] }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(u1, u2)
    end
  end

  # ── T18-13: HABTM NOT EXISTS + scoping ──────────────────────────────────────
end

RSpec.describe 'round18' + ' - ' + 'HABTM NOT EXISTS with scoping' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
      end
    end
  end

  # ── T18-1: Temporal predications ─────────────────────────────────────────────

  describe 'HABTM NOT EXISTS with scoping' do
    def user_with_emails(addresses)
      user = create(:user, emails_count: 0)
      addresses.each { |addr| user.emails << create(:email, address: addr) }
      user
    end

    it 'count == 0 with include_zero and scoping uses NOT EXISTS for HABTM' do
      u1 = user_with_emails(%w[admin@test.com user@test.com])
      u2 = user_with_emails(%w[hello@other.com])
      u3 = user_with_emails([])

      # Count emails matching address LIKE '%test.com%' == 0, include_zero: true
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'emails', aggregate: 'count',
            predicate: 'eq', args: [0],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'address', predicate: 'matches', args: ['test.com'] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      # u1 has test.com emails → excluded
      # u2 has no test.com emails → included
      # u3 has no emails at all → included
      expect(result).to include(u2, u3)
      expect(result).not_to include(u1)
    end
  end

  # ── T18-15: PermissionResolver unknown list_type ────────────────────────────
end

RSpec.describe 'round18' + ' - ' + 'PermissionResolver unknown list_type' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
      end
    end
  end

  # ── T18-1: Temporal predications ─────────────────────────────────────────────

  describe 'PermissionResolver unknown list_type' do
    it 'raises FilterError for unrecognized list_type' do
      permissions = [{ list_type: :invalid, block: ->(_ctx) { [:foo] } }]

      expect {
        Scry::PermissionResolver.reduce(
          [:foo, :bar],
          permissions: permissions,
          context: nil
        )
      }.to raise_error(Scry::FilterError, /unrecognized list_type/)
    end
  end

  # ── A18-2: NOT EXISTS has_one optimization ──────────────────────────────────
end

RSpec.describe 'round18' + ' - ' + 'NOT EXISTS has_one optimization' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
      end
    end
  end

  # ── T18-1: Temporal predications ─────────────────────────────────────────────

  describe 'NOT EXISTS has_one optimization' do
    it 'count == 0 with include_zero and scoping works for has_one' do
      Account.add_filter_permission(:associations) { |_ctx| [:primary_user] }
      Account.add_filter_permission(:aggregates) do |_ctx|
        { 'primary_user' => { 'count' => true } }
      end
      Account.scry_permissions.clear_caches!

      acc1 = Account.create!(username: 'with_user', password: 'x')
      acc2 = Account.create!(username: 'no_user', password: 'x')
      acc3 = Account.create!(username: 'diff_user', password: 'x')

      create(:user, account: acc1, first_name: 'Alice')
      create(:user, account: acc3, first_name: 'Bob')

      # Accounts with zero primary_users named 'Alice'
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'primary_user', aggregate: 'count',
            predicate: 'eq', args: [0],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: Account, filter: filter, context: nil).relation
      # acc1 has Alice → excluded
      # acc2 has no user → included
      # acc3 has Bob (not Alice) → included
      expect(result).to include(acc2, acc3)
      expect(result).not_to include(acc1)
    end
  end
end
