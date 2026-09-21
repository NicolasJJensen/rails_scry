# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round19' + ' - ' + 'Transform and formatter error handling' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
      end
    end
  end

  # ── T19-2: Transform/formatter error handling ──────────────────────────────

  describe 'Transform and formatter error handling' do
    it 'matches none when an attribute transform fails' do
      Scry.configuration.callback_error_policy = :match_none
      User.add_filter_transform(:first_name, on: :attribute) { |_attr, _ctx| raise 'attribute transform error' }
      User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[eq] } }
      User.scry_permissions.clear_caches!

      u = create(:user, first_name: 'Test')

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Test'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).not_to include(u)
    end

    it 'matches none when a value transform fails' do
      Scry.configuration.callback_error_policy = :match_none
      User.add_filter_transform(:first_name, on: :value) { |_val, _ctx| raise 'value transform error' }
      User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[eq] } }
      User.scry_permissions.clear_caches!

      u = create(:user, first_name: 'Test')

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Test'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).not_to include(u)
    end

    it 'matches none when a predicate formatter fails' do
      Scry.configuration.callback_error_policy = :match_none
      Scry.configuration.register_predicate(
        :exploding_eq, types: [:textual], formatter: ->(_value) { raise 'formatter exploded' }
      ) { |attr, value| attr.eq(value) }

      User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[exploding_eq] } }
      User.scry_permissions.clear_caches!

      create(:user, first_name: 'Test')

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'exploding_eq', args: ['Test'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to be_empty
    end
  end

  # ── T19-6+11: Custom property filter edge cases ───────────────────────────
end

RSpec.describe 'round19' + ' - ' + 'Custom property filter edge cases' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
      end
    end
  end

  # ── T19-2: Transform/formatter error handling ──────────────────────────────

  describe 'Custom property filter edge cases' do
    it 'handles custom property filter returning nil definition' do
      User.add_filter_permission(:custom_property_filters) { |_ctx| { virtual_field: nil } }
      User.scry_permissions.clear_caches!

      create(:user)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'virtual_field', predicate: 'eq', args: ['x'] }
        ]
      }

      # custom_property_filters returns { virtual_field: nil }
      # Property#apply detects nil → handle_error → group skips → returns all
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result.count).to eq(User.count)
    end

    it 'raises ArgumentError when both function and block given to add_filter_permission' do
      expect {
        User.add_filter_permission(:properties, :some_method) { |_ctx| [:first_name] }
      }.to raise_error(ArgumentError, /both a block and a function/)
    end
  end

  # ── T19-18+19+20: NameError rescue paths ───────────────────────────────────
end

RSpec.describe 'round19' + ' - ' + 'NameError rescue paths' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
      end
    end
  end

  # ── T19-2: Transform/formatter error handling ──────────────────────────────

  describe 'NameError rescue paths' do
    it 'handles NameError in association filter when model class is missing' do
      create(:user)

      # Stub the reflection's klass to raise NameError
      reflection = User.reflect_on_association(:emails)
      allow(User).to receive(:reflect_on_association).and_call_original
      allow(User).to receive(:reflect_on_association).with('emails').and_return(reflection)
      allow(reflection).to receive(:klass).and_raise(NameError.new('uninitialized constant MissingModel'))

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'emails', predicate: 'has_any', args: [[1]] }
        ]
      }

      # NameError caught → handle_error → nil → group skips → returns all
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result.count).to eq(User.count)
    end

    it 'handles NameError in aggregate filter when model class is missing' do
      create(:user)

      reflection = User.reflect_on_association(:emails)
      allow(User).to receive(:reflect_on_association).and_call_original
      allow(User).to receive(:reflect_on_association).with('emails').and_return(reflection)
      allow(reflection).to receive(:klass).and_raise(NameError.new('uninitialized constant MissingModel'))

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [0] }
        ]
      }

      # NameError caught → handle_error → nil → group skips → returns all
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result.count).to eq(User.count)
    end

    it 'handles NameError in aggregate through-reflection when join model is missing' do
      tech = Technician.create!(name: 'T', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})

      # Technician → jobs is has_many :through (via schedule_assignments)
      reflection = Technician.reflect_on_association(:jobs)
      through_ref = reflection.through_reflection
      allow(Technician).to receive(:reflect_on_association).and_call_original
      allow(Technician).to receive(:reflect_on_association).with('jobs').and_return(reflection)
      allow(through_ref).to receive(:klass).and_raise(NameError.new('uninitialized constant MissingJoinModel'))

      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'jobs', aggregate: 'count',
            predicate: 'eq', args: [0],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'title', predicate: 'eq', args: ['Test'] }
              ]
            }
          }
        ]
      }

      # NameError on through model → handle_error → nil → group skips → returns all
      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result.count).to eq(Technician.count)
    end
  end

  # ── Aggregate predicate permission validation ────────────────────────────
end

RSpec.describe 'round19' + ' - ' + 'Aggregate predicate permission validation' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
      end
    end
  end

  # ── T19-2: Transform/formatter error handling ──────────────────────────────

  describe 'Aggregate predicate permission validation' do
    def user_with_emails(count)
      user = create(:user, emails_count: 0)
      count.times { user.emails << create(:email) }
      user
    end

    it 'rejects aggregate predicate blacklisted via type_predicates' do
      User.add_filter_permission(:type_predicates, list_type: :blacklist) { |_ctx| { numerical: [:gt] } }
      User.scry_permissions.clear_caches!

      user_with_emails(3)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [2] }
        ]
      }

      # :gt is blacklisted → aggregate filter rejected → group skips → returns all
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result.count).to eq(User.count)
    end

    it 'allows aggregate predicate not blacklisted' do
      User.add_filter_permission(:type_predicates, list_type: :blacklist) { |_ctx| { numerical: [:gt] } }
      User.scry_permissions.clear_caches!

      u1 = user_with_emails(3)
      _u2 = user_with_emails(1)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'eq', args: [3] }
        ]
      }

      # :eq is NOT blacklisted → aggregate works normally
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to match_array([u1])
    end
  end

  # ── T19-9: HashPermissionResolver nil block return ─────────────────────────
end

RSpec.describe 'round19' + ' - ' + 'HashPermissionResolver nil block return' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
      end
    end
  end

  # ── T19-2: Transform/formatter error handling ──────────────────────────────

  describe 'HashPermissionResolver nil block return' do
    it 'handles nil return from custom_property_filters permission block' do
      User.add_filter_permission(:custom_property_filters) { |_ctx| nil }
      User.scry_permissions.clear_caches!

      # Should not raise; nil is treated as empty hash by HashPermissionResolver
      filters = User.scry_permissions.allowed_custom_property_filters(nil)
      expect(filters).to be_a(Hash)
    end
  end
end
