require 'rails_helper'

RSpec.describe Scry::Configuration do
  subject(:config) { described_class.instance }

  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      example.run
    end
  end

  describe '#filter_class_mappings' do
    it 'exposes a mapping for :group, :association, and :property' do
      mappings = config.filter_class_mappings
      expect(mappings[:group]).to eq(Scry::Filters::Group)
      expect(mappings[:association]).to eq(Scry::Filters::Association)
      expect(mappings[:property]).to eq(Scry::Filters::Property)
    end

    it 'allows registering a new filter type via register_filter' do
      klass = Class.new(Scry::Filters::Base) { def apply = @scope }
      config.register_filter(:my_special, klass)
      expect(config.filter_class_mappings[:my_special]).to eq(klass)
    end

    it 'does not coerce mapping entries into arrays unexpectedly' do
      expect(config.filter_class_mappings[:group]).to be < Scry::Filters::Base
      expect(config.filter_class_mappings[:association]).to be < Scry::Filters::Base
      expect(config.filter_class_mappings[:property]).to be < Scry::Filters::Base
    end
  end

  describe '#lock_settings!' do
    it 'rejects ordinary setting changes after settings are locked' do
      config.lock_settings!

      expect { config.callback_error_policy = :match_none }
        .to raise_error(Scry::FilterError, /settings are locked/)
      expect { config.strict = true }
        .to raise_error(Scry::FilterError, /settings are locked/)
      expect { config.logger = Logger.new($stderr) }
        .to raise_error(Scry::FilterError, /settings are locked/)
    end

    it 'keeps temporary settings mutable and does not change the locked global settings' do
      config.lock_settings!
      original = config.callback_error_policy

      config.with_temporary_settings do |temporary|
        expect(temporary).not_to be_settings_locked
        temporary.callback_error_policy = :match_none
        expect(temporary.callback_error_policy).to eq(:match_none)
      end

      expect(config).to be_settings_locked
      expect(config.callback_error_policy).to eq(original)
    end

    it 'restores the locked global settings when a temporary block raises' do
      config.lock_settings!

      expect {
        config.with_temporary_settings do |temporary|
          temporary.strict = true
          raise "stop"
        end
      }.to raise_error("stop")

      expect(config).to be_settings_locked
    end
  end

  describe '#register_predicate' do
    it 'defaults custom predicates to property filters only' do
      config.register_predicate(:property_only, types: [:textual], compounds: false) { |attr, value| attr.eq(value) }

      expect(config.predicate_registry.by_name(:property_only)[:applies_to]).to eq([:property])
    end

    it 'records explicit filter kinds for custom predicates' do
      config.register_predicate(
        :expression_predicate,
        types: [:numerical],
        applies_to: %i[computed aggregate],
        compounds: false
      ) { |attr, value| attr.eq(value) }

      expect(config.predicate_registry.by_name(:expression_predicate)[:applies_to])
        .to eq(%i[computed aggregate])
    end

    it 'rejects unknown predicate filter kinds' do
      expect {
        config.register_predicate(:invalid_kind, applies_to: [:record], compounds: false) { |attr| attr.eq(1) }
      }.to raise_error(ArgumentError, /applies_to/)
    end

    it 'exposes built-in predicate filter kinds through the same registry metadata' do
      expect(config.predicate_registry.by_name(:eq)[:applies_to])
        .to contain_exactly(:property, :computed, :aggregate)
      expect(config.predicate_registry.by_name(:has_any)[:applies_to]).to eq([:association])
    end

    it 'registers base, _any, and _all forms when compounds=true with arel_predicate' do
      config.register_predicate(:demo_pred, types: [:textual], compounds: true, arel_predicate: :eq)
      pr = config.predicate_registry
      expect(pr.by_name(:demo_pred)).to be_present
      expect(pr.by_name(:demo_pred_any)).to be_present
      expect(pr.by_name(:demo_pred_all)).to be_present
    end

    it 'generates compound variants for custom block predicates when enabled' do
      config.register_predicate(:demo_block_pred, types: [:textual], compounds: true) { |attr, v| attr.eq(v) }
      pr = config.predicate_registry
      expect(pr.by_name(:demo_block_pred)).to be_present
      expect(pr.by_name(:demo_block_pred_any)).to be_present
      expect(pr.by_name(:demo_block_pred_all)).to be_present
    end

    it 'derives parameter metadata from a normal two-argument block signature' do
      config.register_predicate(:arity_demo, types: [:numerical]) { |attr, lower, upper| attr.between(lower..upper) }
      pred = config.predicate_registry.by_name(:arity_demo)
      expect(pred[:parameters].map { |parameter| [parameter[:name], parameter[:kind]] }).to eq([[:lower, :required], [:upper, :required]])
      expect(pred[:arguments].symbolize_keys).to eq({ min: 2, max: 2 })
      expect(pred[:types]).to include(:numerical)
    end

    it 'rejects block and arel_predicate when both provided' do
      blk = ->(attr, v) { attr.eq(v) }
      expect { config.register_predicate(:prefer_block, types: [:textual], arel_predicate: :matches, &blk) }
        .to raise_error(ArgumentError, /both/)
    end

    it 'supports unregistering predicates entirely' do
      config.register_predicate(:to_remove, types: [:textual]) { |attr, v| attr.eq(v) }
      expect(config.predicate_registry.by_name(:to_remove)).to be_present
      config.unregister_predicate(:to_remove, :to_remove_any, :to_remove_all)
      expect(config.predicate_registry.by_name(:to_remove)).to be_nil
      expect(config.predicate_registry.by_name(:to_remove_any)).to be_nil
      expect(config.predicate_registry.by_name(:to_remove_all)).to be_nil
    end

    it 'supports unregistering predicates from a specific type' do
      config.register_predicate(:scoped_remove, types: [:textual, :numerical]) { |attr, v| attr.eq(v) }
      expect(config.predicate_registry.by_type(:textual)).to include(:scoped_remove)
      config.unregister_predicate_from_type(:textual, :scoped_remove)
      expect(config.predicate_registry.by_type(:textual)).not_to include(:scoped_remove)
      expect(config.predicate_registry.by_type(:numerical)).to include(:scoped_remove)
    end
  end

  describe 'type group management' do
    it 'registers type groups and exposes them via #types' do
      config.register_types(:my_group, :t1, :t2)
      expect(config.types).to include(:my_group, :t1, :t2)
    end

    it 'unregisters groups via #unregister_types' do
      config.register_types(:old_group, :x)
      expect(config.types).to include(:old_group)
      config.unregister_types(:old_group)
      expect(config.types).not_to include(:old_group)
    end

    it 'unregisters specific types from a group via #unregister_types_from_group' do
      config.register_types(:another_group, :y1, :y2)
      expect(config.types).to include(:another_group, :y1, :y2)
      config.unregister_types_from_group(:another_group, :y1)
      # After removing :y1, the type list should still include :another_group and :y2
      expect(config.types).to include(:another_group, :y2)
    end
  end
end
