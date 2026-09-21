# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round31' + ' - ' + 'filter_capabilities error fallback' do
  describe 'filter_capabilities error fallback' do
    it 'returns error: true when filter_capabilities fails under :skip policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :skip

        # Force an error by passing a non-model class
        result = Scry.filter_capabilities(model: String)
        expect(result[:error]).to be true
        expect(result[:properties]).to eq([])
      end
    end

    it 'returns error: true when filter_capabilities fails with diagnostic logging enabled' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn

        expect(Rails.logger).to receive(:warn).with(/filter_capabilities failed/)
        result = Scry.filter_capabilities(model: String)
        expect(result[:error]).to be true
      end
    end

    it 'does not include error key on successful filter_capabilities' do
      result = Scry.filter_capabilities(model: User)
      expect(result).not_to have_key(:error)
    end
  end

  # ── W5: Silent transform failures expose safe diagnostics ───────────────
end

RSpec.describe 'round31' + ' - ' + 'Transform failure debug logging' do
  describe 'Transform failure debug logging' do
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

    it 'records a redacted diagnostic under :skip policy when a transform fails' do
      Scry.configuration.callback_error_policy = :match_none

      User.add_filter_transform(:first_name, on: :attribute) do |_attr, _ctx|
        raise RuntimeError, 'kaboom'
      end
      User.scry_permissions.clear_caches!

      user = create(:user, first_name: 'Alice')

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        ]
      }

      result = Scry.filter_records_by(
        records: User.where(id: user.id), filter: filter, context: nil
      )
      expect(result.relation).to be_none
      diagnostic = result.diagnostics.find { |entry| entry.code == :callback_error }
      expect(diagnostic).to have_attributes(
        code: :callback_error,
        message: /attribute transform callback failed/
      )
      expect(diagnostic.message).not_to include('kaboom')
    end
  end

  # ── W7: Thread cache correctly caches nil and false values ──────────────
end

RSpec.describe 'round31' + ' - ' + 'Thread cache nil/false caching' do
  describe 'Thread cache nil/false caching' do
    after(:each) do
      Thread.current[:scry_caches] = nil
    end

    it 'caches nil values without re-evaluating the block' do
      perms = User.scry_permissions
      call_count = 0

      result1 = perms.thread_cache(:test_nil, :ctx, diagnostic_context: :ctx) do
        call_count += 1
        nil
      end

      result2 = perms.thread_cache(:test_nil, :ctx, diagnostic_context: :ctx) do
        call_count += 1
        'should not reach'
      end

      expect(call_count).to eq(1)
      expect(result1).to be_nil
      expect(result2).to be_nil
    end

    it 'caches false values without re-evaluating the block' do
      perms = User.scry_permissions
      call_count = 0

      result1 = perms.thread_cache(:test_false, :ctx, diagnostic_context: :ctx) do
        call_count += 1
        false
      end

      result2 = perms.thread_cache(:test_false, :ctx, diagnostic_context: :ctx) do
        call_count += 1
        'should not reach'
      end

      expect(call_count).to eq(1)
      expect(result1).to be false
      expect(result2).to be false
    end
  end

  # ── S1: Identifier character validation ─────────────────────────────────
end

RSpec.describe 'round31' + ' - ' + 'safe_to_sym character validation' do
  describe 'safe_to_sym character validation' do
    it 'rejects identifiers with invalid characters under :raise policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise

        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first name; DROP TABLE users', predicate: 'eq', args: ['x'] }
          ]
        }

        expect {
          Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        }.to raise_error(Scry::FilterError, /identifier contains invalid characters/)
      end
    end

    it 'rejects identifiers starting with a digit' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise

        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: '123abc', predicate: 'eq', args: ['x'] }
          ]
        }

        expect {
          Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        }.to raise_error(Scry::FilterError, /identifier contains invalid characters/)
      end
    end

    it 'accepts valid Ruby identifiers with underscores' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise

        user = create(:user, first_name: 'Valid')
        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Valid'] }
          ]
        }

        result = Scry.filter_records_by(
          records: User.where(id: user.id), filter: filter, context: nil
        ).relation
        expect(result).to match_array([user])
      end
    end
  end

  # ── Registry mutation warnings ────────────────────────────────────────────
end

RSpec.describe 'round31' + ' - ' + 'VALID_LIST_TYPES constant' do
  describe 'VALID_LIST_TYPES constant' do
    it 'is accessible as Scry::Filterable::VALID_LIST_TYPES' do
      expect(Scry::Filterable::VALID_LIST_TYPES).to eq(%i[whitelist blacklist includelist excludelist])
    end

    it 'is frozen' do
      expect(Scry::Filterable::VALID_LIST_TYPES).to be_frozen
    end
  end

  # ── W6: cached closures remain immutable across registration ────────────
end

RSpec.describe 'round31' + ' - ' + 'TypeRegistry register allocation' do
  describe 'TypeRegistry register allocation' do
    it 'keeps earlier closures independent of later registrations' do
      registry = Scry::TypeRegistry.new
      registry.register(:test_group, :type_a)

      before = registry.by_group(:test_group)

      registry.register(:test_group, :type_b)

      after = registry.by_group(:test_group)
      expect(before).to include(:type_a)
      expect(before).not_to include(:type_b)
      expect(after).to include(:type_a, :type_b)
    end
  end
end

RSpec.describe 'registry warm and restore lifecycle' do
  it 'precomputes transitive type closures when warmed' do
    registry = Scry::TypeRegistry.new
    registry.register(:parent, :child1, :child2)
    registry.register(:child1, :grandchild)

    registry.warm!

    expect(registry.warmed?).to be(true)
    expect(registry.by_group(:parent)).to include(:child1, :child2, :grandchild)
  end

  it 'invalidates warmed type closures and advances the revision after registration' do
    registry = Scry::TypeRegistry.new
    registry.warm!
    revision = registry.revision

    registry.register(:late_addition, :something)

    expect(registry.warmed?).to be(true)
    expect(registry.revision).to be > revision
    expect(registry.by_group(:late_addition)).to include(:something)
  end

  it 'warms the base registry and its type registry together' do
    registry = Scry::PredicateRegistry.new

    registry.warm!

    expect(registry.warmed?).to be(true)
    expect(registry.type_registry.warmed?).to be(true)
  end

  it 'advances the base registry cache key after registration while warmed' do
    registry = Scry::PredicateRegistry.new
    registry.warm!
    revision = registry.cache_key.first

    registry.register({name: :late_predicate, arel_predicate: :eq, types: [:all]})

    expect(registry.warmed?).to be(true)
    expect(registry.cache_key.first).to be > revision
    expect(registry.by_name(:late_predicate)).to be_present
  end

  it 'unwarms a base registry when restoring a snapshot' do
    registry = Scry::PredicateRegistry.new
    snapshot = registry.snapshot
    registry.warm!

    registry.restore(snapshot)

    expect(registry.warmed?).to be(false)
    expect(registry.type_registry.warmed?).to be(false)
  end
end
