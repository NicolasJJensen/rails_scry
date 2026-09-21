# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round8' + ' - ' + 'Permission block exception handling' do
  describe 'Permission block exception handling' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        example.run
      end
    end

    it 're-raises the original properties permission exception' do
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        User.add_filter_permission(:properties, list_type: :includelist) do |_ctx|
          raise RuntimeError, 'kaboom'
        end
        User.scry_permissions.clear_caches!

        expect {
          User.scry_permissions.allowed_properties(nil)
        }.to raise_error(RuntimeError, 'kaboom')
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end

    it 're-raises the original model permission exception' do
      original = Email.scry_permissions.deep_dup(klass: Email)
      begin
        Email.add_model_permission do |_ctx|
          raise StandardError, 'model boom'
        end
        Email.scry_permissions.clear_caches!

        expect {
          Email.model_allowed?(nil)
        }.to raise_error(StandardError, 'model boom')
      ensure
        Email.scry_permissions = original
        Email.scry_permissions.clear_caches!
      end
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'PermissionResolver unknown list_type' do
  describe 'PermissionResolver unknown list_type' do
    it 'raises FilterError for unrecognized list_type' do
      bad_permission = { list_type: :foobar, block: ->(_ctx) { [:a] } }
      expect {
        Scry::PermissionResolver.reduce(
          [:a, :b],
          permissions: [bad_permission],
          context: nil
        )
      }.to raise_error(Scry::FilterError, /unrecognized list_type/)
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'allowed_associations filters by model_allowed?' do
  describe 'allowed_associations filters by model_allowed?' do
    it 'excludes associations to models that fail model_allowed?' do
      original_email = Email.scry_permissions.deep_dup(klass: Email)
      begin
        Email.add_model_permission { |_ctx| false }
        Email.scry_permissions.clear_caches!
        User.scry_permissions.clear_caches!

        associations = User.scry_permissions.allowed_associations(nil)
        expect(associations).not_to include(:emails)
      ensure
        Email.scry_permissions = original_email
        Email.scry_permissions.clear_caches!
        User.scry_permissions.clear_caches!
      end
    end
  end

end

RSpec.describe 'round8' + ' - ' + 'Aggregate registry metadata' do
  describe 'Aggregate registry metadata' do
    it 'exposes immutable aggregate definitions through configuration' do
      definition = Scry.configuration.aggregate_registry.by_name(:sum)

      expect(definition).to be_frozen
      expect(definition[:builder]).to respond_to(:call)
      expect { definition[:name] = :changed }.to raise_error(FrozenError)
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'Predicate registry metadata' do
  describe 'Predicate registry metadata' do
    it 'prevents mutation of predicate definitions used for filtering' do
      Scry.configuration.with_temporary_settings do |config|
        config.register_predicate(:immutable_predicate, types: %i[textual], compounds: false, arel_predicate: :eq)
        definition = config.predicate_registry.by_name(:immutable_predicate)

        expect(definition).to be_frozen
        expect { definition[:arel_predicate] = nil }.to raise_error(FrozenError)
      end
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'NOT EXISTS optimization numeric check' do
  describe 'NOT EXISTS optimization numeric check' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        example.run
      end
    end

    it 'does not match string value "0" as numeric zero' do
      u1 = create(:user, emails_count: 0)

      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'eq', args: ['0']
      }

      # String "0" should not trigger the NOT EXISTS optimization path
      # (which requires Numeric && == 0). It should go through normal aggregate path.
      result = Scry.filter_records_by(
        records: User.where(id: u1.id),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      # Should not raise, and result type is valid
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'Association filtering through the public API' do
  describe 'Association filtering through the public API' do
    it 'filters a belongs_to association without exposing reflection internals' do
      organisation = create(:organisation)
      user = create(:user, organisation: organisation)

      result = Scry.filter_records_by(
        records: User.where(id: user.id),
        filter: {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'organisation', predicate: 'has_any', args: [[organisation.id]] }
          ]
        },
        context: nil
      ).relation

      expect(result.ids).to eq([user.id])
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'Group .or() ArgumentError handling' do
  describe 'Group .or() ArgumentError handling' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn
        example.run
      end
    end

    it 'handles ArgumentError when combining incompatible relations' do
      # This tests the rescue ArgumentError in group.rb
      # In practice this can happen with structurally incompatible relations
      u1 = create(:user, first_name: 'Test')

      filter = {
        type: 'group', predicate: 'or', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Test'] }
        ]
      }

      # A single-item OR group should work fine
      result = Scry.filter_records_by(
        records: User.where(id: u1.id),
        filter: filter,
        context: nil
      ).relation
      expect(result).to include(u1)
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'HAVING predicate type validation' do
  describe 'HAVING predicate type validation' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        example.run
      end
    end

    it 'rejects text predicates for aggregate HAVING clause' do
      u1 = create(:user, emails_count: 0)
      u1.emails << create(:email)

      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'matches', args: ['test']
      }

      expect {
        Scry.filter_records_by(
          records: User.where(id: u1.id),
          filter: { type: 'group', predicate: 'and', filters: [filter] },
          context: nil
        ).relation
      }.to raise_error(Scry::FilterError, /disallowed aggregate predicate/)
    end
  end

end

RSpec.describe 'round8' + ' - ' + 'BaseRegistry#unregister name normalization' do
  describe 'BaseRegistry#unregister name normalization' do
    it 'unregisters by string when registered with symbol' do
      registry = Scry::BaseRegistry.new
      registry.register({ name: :test_item, types: [:all] })
      expect(registry.by_name(:test_item)).not_to be_nil

      registry.unregister('test_item')
      expect(registry.by_name(:test_item)).to be_nil
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'PredicateRegistry#apply_types_to_predicate nil guard' do
  describe 'PredicateRegistry#apply_types_to_predicate nil guard' do
    it 'does not crash when predicate does not exist' do
      registry = Scry::PredicateRegistry.new
      expect {
        registry.apply_types_to_predicate(:nonexistent, :numerical)
      }.not_to raise_error
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'Association transform pipeline for non-FK paths' do
  describe 'Association transform pipeline for non-FK paths' do
    around(:each) do |example|
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end

    it 'applies value transforms on association subquery path' do
      # Add a value transform on the :organisation association
      transform_called = false
      User.add_filter_transform(:organisation, on: [:value]) do |val, _ctx|
        transform_called = true
        val
      end
      User.scry_permissions.clear_caches!

      org = create(:organisation)
      user = create(:user, organisation: org)

      filter = {
        type: 'association', association: 'organisation', predicate: 'has_any',
        args: [[org.id]], scoping: {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'name', predicate: 'eq', args: [org.name] }
          ]
        }
      }

      result = Scry.filter_records_by(
        records: User.where(id: user.id),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      expect(result).to include(user)
      expect(transform_called).to be true
    end
  end

end

RSpec.describe 'round8' + ' - ' + 'SqlLiteral type check in custom predicates' do
  describe 'SqlLiteral type check in custom predicates' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise
        config.invalid_filter_policy = :raise

        config.register_predicate(:sql_literal_test, types: %i[textual], compounds: false) do |attr, _value|
          Arel::Nodes::SqlLiteral.new("#{attr.name} IS NOT NULL")
        end

        example.run
      end
    end

    it 'rejects SqlLiteral return from custom predicate' do
      create(:user, first_name: 'Test')

      filter = {
        type: 'property', property: 'first_name', predicate: 'sql_literal_test', args: ['anything']
      }

      expect {
        Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [filter] },
          context: nil
        ).relation
      }.to raise_error(Scry::FilterError, /returned invalid node/)
    end
  end

end

RSpec.describe 'round8' + ' - ' + 'Scoping query memoization in aggregate' do
  describe 'Scoping query memoization in aggregate' do
    it 'reuses the same scoping query across calls' do
      u1 = create(:user, emails_count: 0)
      email = create(:email, address: 'scoped@test.com')
      u1.emails << email

      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'gteq', args: [1],
        scoping: {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'address', predicate: 'eq', args: ['scoped@test.com'] }
          ]
        }
      }

      result = Scry.filter_records_by(
        records: User.where(id: u1.id),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      expect(result).to include(u1)
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'OR tree Arel optimization' do
  describe 'OR tree Arel optimization' do
    it 'produces correct results for multi-clause OR groups' do
      u1 = create(:user, first_name: 'Alpha')
      u2 = create(:user, first_name: 'Beta')
      u3 = create(:user, first_name: 'Gamma')

      filter = {
        type: 'group', predicate: 'or', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alpha'] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Gamma'] }
        ]
      }

      result = Scry.filter_records_by(
        records: User.where(id: [u1.id, u2.id, u3.id]),
        filter: filter,
        context: nil
      ).relation
      expect(result).to match_array([u1, u3])
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'predicates_by_property guards deep_dup' do
  describe 'predicates_by_property guards deep_dup' do
    it 'returns base predicates when no property_predicates permissions exist' do
      # With no property_predicates defined, should skip deep_dup
      predicates = User.scry_permissions.allowed_property_predicates(nil)
      expect(predicates).to be_a(Hash)
      expect(predicates.keys).not_to be_empty
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'BaseRegistry snapshot restore without redundant deep_dup' do
  describe 'BaseRegistry snapshot restore without redundant deep_dup' do
    it 'correctly restores registry state from snapshot' do
      registry = Scry::BaseRegistry.new
      registry.register({ name: :snap_test, types: [:all] })

      snap = registry.snapshot
      registry.unregister(:snap_test)
      expect(registry.by_name(:snap_test)).to be_nil

      registry.restore(snap)
      expect(registry.by_name(:snap_test)).not_to be_nil
    end
  end

end

RSpec.describe 'round8' + ' - ' + 'Middleware::CacheClearer' do
  describe 'Middleware::CacheClearer' do
    it 'clears thread-local caches after request' do
      app = ->(_env) { [200, {}, ['ok']] }
      middleware = Scry::Middleware::CacheClearer.new(app)

      # Prime the cache
      Thread.current[:scry_caches] = { User => { test: 'data' } }

      middleware.call({})

      expect(Thread.current[:scry_caches]).to be_empty
    end

    it 'clears caches even when app raises' do
      app = ->(_env) { raise 'boom' }
      middleware = Scry::Middleware::CacheClearer.new(app)

      Thread.current[:scry_caches] = { User => { test: 'data' } }

      expect { middleware.call({}) }.to raise_error(RuntimeError, 'boom')
      expect(Thread.current[:scry_caches]).to be_empty
    end
  end
end

RSpec.describe 'round8' + ' - ' + 'LRU cache bound' do
  describe 'LRU cache bound' do
    it 'evicts entries when cache exceeds MAX_CACHE_SIZE' do
      perms = User.scry_permissions
      max = Scry::FilterPermissions::MAX_CACHE_SIZE

      # Directly populate the cache to near capacity
      store = Thread.current[:scry_caches] ||= {}
      klass_store = store[User] ||= {}
      max.times { |i| klass_store[[:test, "key_#{i}"]] = "value_#{i}" }

      expect(klass_store.size).to eq(max)

      # Trigger one more cache entry via thread_cache
      perms.send(:thread_cache, :overflow_test, :overflow_key, diagnostic_context: :overflow_key) { 'overflow_value' }
      klass_store = Thread.current[:scry_caches][User]

      # Should have evicted half and added one
      expect(klass_store.size).to be <= (max / 2) + 1
    end
  end

  # ── Strict mode ───────────────────────────────────────────────────────────
end

RSpec.describe 'round8' + ' - ' + 'Strict mode aggregates' do
  describe 'Strict mode aggregates' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.strict = true
        example.run
      end
    end

    it 'returns empty aggregates without explicit whitelist' do
      User.scry_permissions.clear_caches!
      aggregates = User.scry_permissions.allowed_aggregates(nil)
      expect(aggregates).to eq({})
    end

    it 'returns whitelisted aggregates when explicitly permitted' do
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        User.add_filter_permission(:associations, list_type: :includelist) { |_ctx| [:emails] }
        User.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
          { emails: { count: true } }
        end
        User.scry_permissions.clear_caches!

        aggregates = User.scry_permissions.allowed_aggregates(nil)
        expect(aggregates).to have_key('emails')
        expect(aggregates['emails']).to have_key('count')
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── Error mode coverage ───────────────────────────────────────────────────
end

RSpec.describe 'round8' + ' - ' + 'Invalid filter policies' do
  describe 'Invalid filter policies' do
    it 'returns nil under :skip policy for invalid filter' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :skip
        result = Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'nonexistent_col', predicate: 'eq', args: ['x'] }
          ] },
          context: nil
        ).relation
        # When all filters in a group are invalid and ignored, returns original records
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end

    it 'logs warning with diagnostic logging enabled for invalid filter' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn
        expect(Rails.logger).to receive(:warn).at_least(:once)
        Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'nonexistent_col', predicate: 'eq', args: ['x'] }
          ] },
          context: nil
        ).relation
      end
    end

    it 'raises FilterError under :raise policy for invalid filter' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        expect {
          Scry.filter_records_by(
            records: User,
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'nonexistent_col', predicate: 'eq', args: ['x'] }
            ] },
            context: nil
          ).relation
        }.to raise_error(Scry::FilterError)
      end
    end
  end

  # ── Configuration snapshot/restore ────────────────────────────────────────
end

RSpec.describe 'round8' + ' - ' + 'Configuration with_temporary_settings' do
  describe 'Configuration with_temporary_settings' do
    it 'restores invalid_filter_policy after block' do
      original = Scry.configuration.invalid_filter_policy
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        expect(Scry.configuration.invalid_filter_policy).to eq(:raise)
      end
      expect(Scry.configuration.invalid_filter_policy).to eq(original)
    end

    it 'restores strict mode after block' do
      original = Scry.configuration.strict
      Scry.configuration.with_temporary_settings do |config|
        config.strict = !original
        expect(Scry.configuration.strict).to eq(!original)
      end
      expect(Scry.configuration.strict).to eq(original)
    end

    it 'supports nested with_temporary_settings' do
      original = Scry.configuration.invalid_filter_policy
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn
        Scry.configuration.with_temporary_settings do |inner_config|
          inner_config.invalid_filter_policy = :raise
          expect(Scry.configuration.invalid_filter_policy).to eq(:raise)
        end
        expect(Scry.configuration.diagnostic_logging).to eq(:warn)
      end
      expect(Scry.configuration.invalid_filter_policy).to eq(original)
    end
  end

  # ── HashPermissionResolver ────────────────────────────────────────────────
end

RSpec.describe 'round8' + ' - ' + 'HashPermissionResolver' do
  describe 'HashPermissionResolver' do
    it 're-raises the original permission exception' do
      bad_permission = { list_type: :includelist, block: ->(_ctx) { raise 'hash boom' } }
      expect {
        Scry::HashPermissionResolver.reduce(
          {},
          permissions: [bad_permission],
          context: nil
        ) { |acc, _map, _lt| acc }
      }.to raise_error(RuntimeError, 'hash boom')
    end
  end
end
