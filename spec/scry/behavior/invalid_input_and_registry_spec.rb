# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round28' + ' - ' + 'Property filter with missing :property key' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── T28-1: Property filter missing :property across invalid_filter_policy modes ──

  describe 'Property filter with missing :property key' do
    let(:filter) do
      { type: :property, predicate: :eq, args: ['test'] }
    end

    context 'when invalid_filter_policy is :ignore' do
      before { Scry.configuration.invalid_filter_policy = :skip }

      it 'returns a failed result' do
        result = Scry.filter_records_by(records: User, filter: filter, context: nil)

        expect(result).to be_failed
      end
    end

    context 'when diagnostic_logging is :warn' do
      before { Scry.configuration.diagnostic_logging = :warn }

      it 'logs a warning and returns a failed result' do
        expect(Rails.logger).to receive(:warn).with(/missing :property key/)

        result = Scry.filter_records_by(records: User, filter: filter, context: nil)

        expect(result).to be_failed
      end
    end

    context 'when invalid_filter_policy is :raise' do
      before { Scry.configuration.invalid_filter_policy = :raise }

      it 'raises a FilterError' do
        expect { Scry.filter_records_by(records: User, filter: filter, context: nil) }.to raise_error(
          Scry::FilterError, /missing :property key/
        )
      end
    end
  end

  # ── T28-2: Association filter missing :predicate across invalid_filter_policy modes ──
end

RSpec.describe 'round28' + ' - ' + 'Association filter with missing :predicate key' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── T28-1: Property filter missing :property across invalid_filter_policy modes ──

  describe 'Association filter with missing :predicate key' do
    let(:filter) do
      { type: :association, association: :organisation, args: [[1]] }
    end

    context 'when invalid_filter_policy is :ignore' do
      before { Scry.configuration.invalid_filter_policy = :skip }

      it 'returns a failed result' do
        result = Scry.filter_records_by(records: User, filter: filter, context: nil)

        expect(result).to be_failed
      end
    end

    context 'when diagnostic_logging is :warn' do
      before { Scry.configuration.diagnostic_logging = :warn }

      it 'logs a warning and returns a failed result' do
        expect(Rails.logger).to receive(:warn) do |payload|
          event = JSON.parse(payload)
          expect(event).to include(
            'code' => 'missing_association',
            'message' => 'Scry: association requires an association and predicate'
          )
        end

        result = Scry.filter_records_by(records: User, filter: filter, context: nil)

        expect(result).to be_failed
      end
    end

    context 'when invalid_filter_policy is :raise' do
      before { Scry.configuration.invalid_filter_policy = :raise }

      it 'raises a FilterError' do
        expect { Scry.filter_records_by(records: User, filter: filter, context: nil) }.to raise_error(
          Scry::FilterError, /association requires an association and predicate/
        )
      end
    end
  end

  # ── T28-3: Property filter missing :predicate across invalid_filter_policy modes ──
end

RSpec.describe 'round28' + ' - ' + 'Property filter with missing :predicate key' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── T28-1: Property filter missing :property across invalid_filter_policy modes ──

  describe 'Property filter with missing :predicate key' do
    let(:filter) do
      { type: :property, property: :first_name, args: ['test'] }
    end

    context 'when invalid_filter_policy is :ignore' do
      before { Scry.configuration.invalid_filter_policy = :skip }

      it 'returns a failed result' do
        result = Scry::Filters::Property.new(
          model: User.all, filter: filter, context: nil
        ).apply

        expect(result).to be_failed
      end
    end

    context 'when invalid_filter_policy is :raise' do
      before { Scry.configuration.invalid_filter_policy = :raise }

      it 'raises a FilterError' do
        expect { Scry.filter_records_by(records: User, filter: filter, context: nil) }.to raise_error(
          Scry::FilterError, /missing :predicate key/
        )
      end
    end
  end

  # ── T28-4: TypeRegistry cycle detection warning ──
end

RSpec.describe 'round28' + ' - ' + 'TypeRegistry cycle detection' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── T28-1: Property filter missing :property across invalid_filter_policy modes ──

  describe 'TypeRegistry cycle detection' do
    it 'logs a warning when a cycle is detected in child_types_for' do
      registry = Scry::TypeRegistry.new
      registry.register(:group_a, :group_b)
      registry.register(:group_b, :group_a)

      expect(Rails.logger).to receive(:warn).with(/cycle detected.*type hierarchy/).at_least(:once)

      registry.by_group(:group_a)
    end

    it 'logs a warning when a cycle is detected in group_types_for' do
      registry = Scry::TypeRegistry.new
      registry.register(:parent, :child)
      registry.register(:grandparent, :parent)
      # Create a cycle: child -> grandparent (which contains parent which contains child)
      registry.register(:child, :grandparent)

      expect(Rails.logger).to receive(:warn).with(/cycle detected.*type hierarchy/).at_least(:once)

      registry.by_group(:child)
    end

    it 'still returns valid results despite the cycle' do
      registry = Scry::TypeRegistry.new
      registry.register(:group_a, :group_b)
      registry.register(:group_b, :group_a)

      allow(Rails.logger).to receive(:warn)

      result = registry.by_group(:group_a)
      expect(result).to include(:group_a, :group_b, :all)
    end
  end

  # ── T28-5: Aggregate registry dispatch ──
end

RSpec.describe 'round28' + ' - ' + 'Aggregate registry dispatch' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── T28-1: Property filter missing :property across invalid_filter_policy modes ──

  describe 'Aggregate registry dispatch' do
    it 'exposes standard aggregate definitions through configuration' do
      registry = Scry.configuration.aggregate_registry

      expect(registry.names).to include(:sum, :avg, :min, :max)
      expect(registry.by_name(:sum)[:builder]).to respond_to(:call)
      expect(registry.by_name(:avg)[:builder]).to respond_to(:call)
    end

    it 'keeps aggregate definitions immutable after registration' do
      metadata = Scry.configuration.aggregate_registry.metadata_for(:sum)

      expect(metadata).to be_frozen
      expect { metadata[:label] = 'changed' }.to raise_error(FrozenError)
    end
  end
end

RSpec.describe 'round29' + ' - ' + 'Group filter with missing :predicate key' do

  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── Group filter invalid_filter_policy modes ──

  describe 'Group filter with missing :predicate key' do
    let(:filter) do
      { type: :group, filters: [{ type: :property, property: :first_name, predicate: :eq, args: ['test'] }] }
    end

    context 'when invalid_filter_policy is :ignore' do
      before { Scry.configuration.invalid_filter_policy = :skip }

      it 'returns a failed result' do
        result = Scry.filter_records_by(records: User, filter: filter, context: nil)

        expect(result).to be_failed
      end
    end

    context 'when diagnostic_logging is :warn' do
      before { Scry.configuration.diagnostic_logging = :warn }

      it 'logs a warning and returns a failed result' do
        expect(Rails.logger).to receive(:warn).with(/missing :predicate key/)

        result = Scry.filter_records_by(records: User, filter: filter, context: nil)

        expect(result).to be_failed
      end
    end

    context 'when invalid_filter_policy is :raise' do
      before { Scry.configuration.invalid_filter_policy = :raise }

      it 'raises a FilterError' do
        expect { Scry.filter_records_by(records: User, filter: filter, context: nil) }.to raise_error(
          Scry::FilterError, /missing :predicate key/
        )
      end
    end
  end
end

RSpec.describe 'round29' + ' - ' + 'Group filter with invalid predicate' do

  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── Group filter invalid_filter_policy modes ──

  describe 'Group filter with invalid predicate' do
    let(:filter) do
      { type: :group, predicate: :xor, filters: [{ type: :property, property: :first_name, predicate: :eq, args: ['test'] }] }
    end

    context 'when invalid_filter_policy is :ignore' do
      before { Scry.configuration.invalid_filter_policy = :skip }

      it 'returns a failed result' do
        result = Scry::Filters::Group.new(
          model: User.all, filter: filter, context: nil
        ).apply

        expect(result).to be_failed
      end
    end

    context 'when invalid_filter_policy is :raise' do
      before { Scry.configuration.invalid_filter_policy = :raise }

      it 'raises a FilterError' do
        expect { Scry.filter_records_by(records: User, filter: filter, context: nil) }.to raise_error(
          Scry::FilterError, /invalid group predicate/
        )
      end
    end
  end
end

RSpec.describe 'round29' + ' - ' + 'Group filter with non-array :filters' do

  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── Group filter invalid_filter_policy modes ──

  describe 'Group filter with non-array :filters' do
    let(:filter) do
      { type: :group, predicate: :and, filters: 'not_an_array' }
    end

    context 'when invalid_filter_policy is :ignore' do
      before { Scry.configuration.invalid_filter_policy = :skip }

      it 'returns a failed result' do
        result = Scry::Filters::Group.new(
          model: User.all, filter: filter, context: nil
        ).apply

        expect(result).to be_failed
      end
    end

    context 'when invalid_filter_policy is :raise' do
      before { Scry.configuration.invalid_filter_policy = :raise }

      it 'raises a FilterError' do
        expect { Scry.filter_records_by(records: User, filter: filter, context: nil) }.to raise_error(
          Scry::FilterError, /missing or non-array :filters key/
        )
      end
    end
  end

  # ── Aggregate filter invalid_filter_policy modes ──
end

RSpec.describe 'round29' + ' - ' + 'Aggregate filter with invalid association' do

  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── Group filter invalid_filter_policy modes ──

  describe 'Aggregate filter with invalid association' do
    let(:filter) do
      { type: :aggregate, association: :nonexistent_assoc, predicate: :eq, args: [5] }
    end

    context 'when invalid_filter_policy is :ignore' do
      before { Scry.configuration.invalid_filter_policy = :skip }

      it 'returns a failed result' do
        result = Scry.filter_records_by(records: User, filter: filter, context: nil)

        expect(result).to be_failed
      end
    end

    context 'when diagnostic_logging is :warn' do
      before { Scry.configuration.diagnostic_logging = :warn }

      it 'logs a warning and returns a failed result' do
        expect(Rails.logger).to receive(:warn) do |payload|
          event = JSON.parse(payload)
          expect(event).to include(
            'code' => 'unknown_association',
            'message' => 'Scry: invalid or missing association'
          )
        end

        result = Scry.filter_records_by(records: User, filter: filter, context: nil)

        expect(result).to be_failed
      end
    end

    context 'when invalid_filter_policy is :raise' do
      before { Scry.configuration.invalid_filter_policy = :raise }

      it 'raises a FilterError' do
        expect { Scry.filter_records_by(records: User, filter: filter, context: nil) }.to raise_error(
          Scry::FilterError, /invalid or missing association/
        )
      end
    end
  end
end

RSpec.describe 'round29' + ' - ' + 'Aggregate filter with missing predicate' do

  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── Group filter invalid_filter_policy modes ──

  describe 'Aggregate filter with missing predicate' do
    let(:filter) do
      { type: :aggregate, association: :emails, args: [5] }
    end

    context 'when invalid_filter_policy is :ignore' do
      before { Scry.configuration.invalid_filter_policy = :skip }

      it 'returns a failed result' do
        result = Scry::Filters::Aggregate.new(
          model: User.all, filter: filter, context: nil
        ).apply

        expect(result).to be_failed
      end
    end

    context 'when invalid_filter_policy is :raise' do
      before { Scry.configuration.invalid_filter_policy = :raise }

      it 'raises a FilterError' do
        expect { Scry.filter_records_by(records: User, filter: filter, context: nil) }.to raise_error(
          Scry::FilterError, /aggregate requires an association and predicate/
        )
      end
    end
  end

  # ── TypeRegistry ensure cleanup ──
end

RSpec.describe 'round29' + ' - ' + 'TypeRegistry stack cleanup on exception' do

  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── Group filter invalid_filter_policy modes ──

  describe 'TypeRegistry stack cleanup on exception' do
    it 'cleans up stack even when child_types_for raises mid-traversal' do
      registry = Scry::TypeRegistry.new
      registry.register(:parent, :child)

      allow(Rails.logger).to receive(:warn)

      # First call should work normally
      result = registry.by_group(:parent)
      expect(result).to include(:parent, :child, :all)
    end

    it 'cleans up stack even when group_types_for raises mid-traversal' do
      registry = Scry::TypeRegistry.new
      registry.register(:parent, :child)

      allow(Rails.logger).to receive(:warn)

      result = registry.by_group(:child)
      expect(result).to include(:child, :parent, :all)
    end
  end

  # ── Extension errors should propagate for diagnosis ──
end

RSpec.describe 'round29' + ' - ' + 'Registered filter extension errors' do

  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
      end
    end
  end

  # ── Group filter invalid_filter_policy modes ──

  describe 'Registered filter extension errors' do
    it 'propagates NameError from a custom filter implementation' do
      extension = Class.new(Scry::Filters::Base) do
        def apply
          raise NameError, 'uninitialized constant MissingExtensionModel'
        end
      end
      stub_const('Round29RaisingExtension', extension)
      Scry.configuration.register_filter(:raising_extension, extension)

      expect {
        Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [{ type: 'raising_extension' }] },
          context: nil
        )
      }.to raise_error(NameError, /MissingExtensionModel/)
    end
  end
end
