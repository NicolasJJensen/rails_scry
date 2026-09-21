# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round20' + ' - ' + 'include_zero aggregate on belongs_to association' do
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

  # ── T20-6: belongs_to LEFT JOIN with include_zero aggregate ──────────────

  describe 'include_zero aggregate on belongs_to association' do
    it 'uses LEFT JOIN and filters correctly' do
      account = create(:account)
      u_with = create(:user, account: account)
      u_without = create(:user, account: nil)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'account', aggregate: 'count',
            predicate: 'eq', args: [1] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(u_with)
      expect(result).not_to include(u_without)
    end
  end

  # ── T20-7: Compound predicate with custom block logs warning ─────────────
end

RSpec.describe 'round20' + ' - ' + 'Compound predicate with custom block' do
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

  # ── T20-6: belongs_to LEFT JOIN with include_zero aggregate ──────────────

  describe 'Compound predicate with custom block' do
    it 'generates _any/_all callbacks for custom blocks' do
      Scry.configuration.register_predicate(
        :custom_compound_test, types: [:all], compounds: true
      ) { |attr, value| attr.eq(value) }

      registry = Scry.configuration.predicate_registry
      expect(registry.by_name(:custom_compound_test)).to be_present
      expect(registry.by_name(:custom_compound_test_any)).to be_present
      expect(registry.by_name(:custom_compound_test_all)).to be_present
    end
  end

  # ── T20-8: Strict mode aggregates start empty ───────────────────────────
end

RSpec.describe 'round20' + ' - ' + 'Strict mode aggregates' do
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

  # ── T20-6: belongs_to LEFT JOIN with include_zero aggregate ──────────────

  describe 'Strict mode aggregates' do
    it 'starts with empty aggregates' do
      Scry.configuration.strict = true
      User.scry_permissions.clear_caches!

      aggs = User.scry_permissions.allowed_aggregates(nil)
      expect(aggs).to be_empty
    end

    it 'allows aggregates via includelist' do
      Scry.configuration.strict = true
      User.add_filter_permission(:associations, list_type: :includelist) { [:emails] }
      User.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
        { emails: { count: true } }
      end
      User.scry_permissions.clear_caches!

      aggs = User.scry_permissions.allowed_aggregates(nil)
      expect(aggs).to have_key('emails')
      expect(aggs['emails']).to have_key('count')
    end
  end

  # ── T20-10: type_predicates includelist with :all ────────────────────────
end

RSpec.describe 'round20' + ' - ' + 'type_predicates includelist with :all' do
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

  # ── T20-6: belongs_to LEFT JOIN with include_zero aggregate ──────────────

  describe 'type_predicates includelist with :all' do
    it 'expands to full registry set for the type' do
      # Excludelist removes :gt from numerical
      User.add_filter_permission(:type_predicates, list_type: :excludelist) { |_ctx| { numerical: [:gt] } }
      User.scry_permissions.clear_caches!

      # Verify :gt was removed from the numerical bucket
      type_preds = User.scry_permissions.send(:predicates_by_type, nil)
      expect(type_preds[:numerical]).not_to include(:gt)

      # Includelist :all adds back all predicates for that type (covers line 263-264)
      User.add_filter_permission(:type_predicates, list_type: :includelist) { |_ctx| { numerical: :all } }
      User.scry_permissions.clear_caches!

      type_preds = User.scry_permissions.send(:predicates_by_type, nil)
      expect(type_preds[:numerical]).to include(:gt, :lt, :eq)
    end
  end

  # ── T20-11: add_filter_transform rejects invalid `on` target ────────────
end

RSpec.describe 'round20' + ' - ' + 'add_filter_transform with invalid target' do
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

  # ── T20-6: belongs_to LEFT JOIN with include_zero aggregate ──────────────

  describe 'add_filter_transform with invalid target' do
    it 'raises ArgumentError for invalid on: value' do
      expect {
        User.add_filter_transform(:first_name, on: :invalid_target) { |v, _ctx| v }
      }.to raise_error(ArgumentError, /on must be one or more of/)
    end
  end

  # ── T20-13: unregister_from_type leaves predicate in by_name ─────────────
end

RSpec.describe 'round20' + ' - ' + 'BaseRegistry#unregister_from_type' do
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

  # ── T20-6: belongs_to LEFT JOIN with include_zero aggregate ──────────────

  describe 'BaseRegistry#unregister_from_type' do
    it 'removes from type list but keeps in by_name' do
      registry = Scry.configuration.predicate_registry

      Scry.configuration.register_predicate(
        :test_unreg_type, types: [:numerical], compounds: false,
        arel_predicate: :eq
      )
      expect(registry.by_name(:test_unreg_type)).to be_present
      expect(registry.by_type(:numerical)).to include(:test_unreg_type)

      registry.unregister_from_type(:numerical, :test_unreg_type)

      expect(registry.by_name(:test_unreg_type)).to be_present
      expect(registry.by_type(:numerical)).not_to include(:test_unreg_type)

      # Clean up
      registry.unregister(:test_unreg_type)
    end
  end

  # ── T20-19: CacheClearer.clear_current_thread! ──────────────────────────
end

RSpec.describe 'round20' + ' - ' + 'CacheClearer.clear_current_thread!' do
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

  # ── T20-6: belongs_to LEFT JOIN with include_zero aggregate ──────────────

  describe 'CacheClearer.clear_current_thread!' do
    it 'clears thread-local permission caches' do
      # Warm the cache by reading permissions
      User.filter_property_permissions(nil)
      expect(Thread.current[:scry_caches]).not_to be_nil

      Scry::Middleware::CacheClearer.clear_current_thread!
      expect(Thread.current[:scry_caches]).to be_empty
    end
  end

  # ── T20-20: Multiple :model permissions warns and keeps last ─────────────
end

RSpec.describe 'round20' + ' - ' + 'Multiple model permissions' do
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

  # ── T20-6: belongs_to LEFT JOIN with include_zero aggregate ──────────────

  describe 'Multiple model permissions' do
    it 'warns and keeps only last model permission' do
      User.add_model_permission { |_ctx| true }

      expect(Rails.logger).to receive(:warn).with(/multiple :model permissions/)
      User.add_model_permission { |_ctx| false }

      expect(User.model_allowed?(nil)).to eq(false)
    end
  end
end
