require 'rails_helper'

RSpec.describe Scry::AggregateRegistry do
  let(:type_registry) { Scry::TypeRegistry.new }
  let(:registry) { described_class.new(type_registry: type_registry) }

  before do
    type_registry.register(:summable, :integer, :float, :decimal)
    type_registry.register(:orderable, :integer, :float, :string)
  end

  describe '#register' do
    it 'registers an aggregate by name' do
      registry.register({ name: :count, types: [:all] })
      expect(registry.by_name(:count)).to be_present
      expect(registry.by_name(:count)[:name].to_sym).to eq(:count)
    end

    it 'registers an aggregate with specific types' do
      registry.register({ name: :sum, types: [:summable] })
      expect(registry.by_name(:sum)[:types]).to include(:summable)
    end

    it 'appears in names after registration' do
      registry.register({ name: :avg, types: [:summable] })
      expect(registry.names).to include(:avg)
    end
  end

  describe '#unregister' do
    before do
      registry.register({ name: :count, types: [:all] })
      registry.register({ name: :sum, types: [:summable] })
    end

    it 'removes an aggregate by name' do
      registry.unregister(:count)
      expect(registry.by_name(:count)).to be_nil
      expect(registry.names).not_to include(:count)
    end

    it 'retains other aggregates' do
      registry.unregister(:count)
      expect(registry.by_name(:sum)).to be_present
    end
  end

  describe '#snapshot and #restore' do
    it 'captures and restores state' do
      registry.register({ name: :count, types: [:all] })
      snapshot = registry.snapshot

      registry.register({ name: :sum, types: [:summable] })
      expect(registry.names).to include(:sum)

      registry.restore(snapshot)
      expect(registry.names).to include(:count)
      expect(registry.names).not_to include(:sum)
    end
  end

  describe '#by_type' do
    before do
      registry.register({ name: :count, types: [:all] })
      registry.register({ name: :sum, types: [:summable] })
      registry.register({ name: :min, types: [:orderable] })
    end

    it 'returns aggregates registered for :all when querying any type' do
      result = registry.by_type(:integer)
      expect(result).to include(:count)
    end

    it 'returns type-specific aggregates' do
      result = registry.by_type(:summable)
      expect(result).to include(:sum)
    end
  end

  describe 'shared type_registry' do
    it 'uses the injected type_registry' do
      expect(registry.type_registry).to eq(type_registry)
    end
  end
end
