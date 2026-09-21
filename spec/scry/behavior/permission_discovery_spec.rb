# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round21' + ' - ' + 'Model permission with invalid return value' do
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

  # ── T21-1: Model permission invalid return value ──────────────────────────

  describe 'Model permission with invalid return value' do
    it 'warns and returns false for non-boolean/nil result' do
      User.add_model_permission { |_ctx| 'some_string' }

      expect(Rails.logger).to receive(:warn).with(/invalid model permission result/)
      expect(User.model_allowed?(nil)).to eq(false)
    end
  end

  # ── T21-6: Association predication ensure_reflection error ────────────────
end

RSpec.describe 'round21' + ' - ' + 'Association predication ensure_reflection' do
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

  # ── T21-1: Model permission invalid return value ──────────────────────────

  describe 'Association predication ensure_reflection' do
    it 'raises ArgumentError when association reflection is missing' do
      # :id is not an association, so reflection will be nil
      attr = User.arel_table[:id].extend(Scry::Predications::Association)
      expect {
        attr.has_any([1])
      }.to raise_error(Scry::FilterError, /invalid or missing association/)
    end
  end

  # ── T21-7: Association predication others_arel invalid type ───────────────
end

RSpec.describe 'round21' + ' - ' + 'Association predication others_arel' do
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

  # ── T21-1: Model permission invalid return value ──────────────────────────

  describe 'Association predication others_arel' do
    it 'accepts a scalar association id' do
      # Scalar IDs use the same set semantics as a one-element ID array.
      attr = User.arel_table[:emails].extend(Scry::Predications::Association)
      expect { attr.has_any(42) }.not_to raise_error
    end
  end

  # ── T21-8: predicates_by_property non-column fallback ─────────────────────
end

RSpec.describe 'round21' + ' - ' + 'predicates_by_property non-column property' do
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

  # ── T21-1: Model permission invalid return value ──────────────────────────

  describe 'predicates_by_property non-column property' do
    it 'limits custom properties without columns to truth predicates' do
      User.add_custom_property_filter(type: :boolean) do |_ctx|
        { virtual_prop: { type: 'group', predicate: 'and', filters: [] } }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_property, nil)
      expect(preds[:virtual_prop]).to contain_exactly(:eq_true, :eq_false)
    end
  end

  # ── T21-9: Filterable.inherited deep_dup independence ─────────────────────
end

RSpec.describe 'round21' + ' - ' + 'Filterable.inherited deep_dup' do
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

  # ── T21-1: Model permission invalid return value ──────────────────────────

  describe 'Filterable.inherited deep_dup' do
    it 'subclass permissions are independent from parent after creation' do
      subclass = Class.new(User)

      # Blacklist :first_name on parent AFTER subclass creation
      User.add_filter_permission(:properties, list_type: :blacklist) { [:first_name] }
      User.scry_permissions.clear_caches!

      # Parent should NOT have :first_name (blacklisted)
      expect(User.filter_property_permissions(nil)).not_to include(:first_name)

      # Subclass should still have :first_name (independent after deep_dup)
      subclass.scry_permissions.clear_caches!
      expect(subclass.filter_property_permissions(nil)).to include(:first_name)
    end
  end

  # ── T21-10: Filterable get_block function name late binding ───────────────
end

RSpec.describe 'round21' + ' - ' + 'Filterable get_block with function name' do
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

  # ── T21-1: Model permission invalid return value ──────────────────────────

  describe 'Filterable get_block with function name' do
    it 'resolves function name via constantize for late binding' do
      User.define_singleton_method(:test_r21_props) { |_ctx| [:last_name] }

      User.add_filter_permission(:properties, :test_r21_props)
      User.scry_permissions.clear_caches!

      props = User.filter_property_permissions(nil)
      expect(props).to include(:last_name)
    ensure
      User.singleton_class.remove_method(:test_r21_props) if User.respond_to?(:test_r21_props)
    end
  end
end
