require 'rails_helper'

RSpec.describe Scry::PredicateRegistry do
    let(:predicate_registry) { described_class.new }

    describe '#initialize' do
      it 'initializes the by_name instance variable' do
        expect(predicate_registry.instance_variable_get(:@by_name)).to eq(HashWithIndifferentAccess.new)
      end

      it 'initializes the by_type instance variable' do
        expect(predicate_registry.instance_variable_get(:@by_type)).to eq(HashWithIndifferentAccess.new([]))
      end
    end

    describe '#register' do
      before do
        predicate_registry.register({ name: :name, types: [:type1, :type2] })
      end

      it 'adds a predicate to the by_name hash' do
        expect(predicate_registry.instance_variable_get(:@by_name)[:name]).to match(name: :name, types: [:type1, :type2])
      end

      it 'adds a predicate to the by_type hash' do
        expect(predicate_registry.instance_variable_get(:@by_type)[:type1]).to match([{ name: :name, types: [:type1, :type2] }])
        expect(predicate_registry.instance_variable_get(:@by_type)[:type2]).to match([{ name: :name, types: [:type1, :type2] }])
      end
    end

    describe '#unregister' do
      before do
        predicate_registry.register({ name: :name, types: [:type1, :type2] })
        predicate_registry.register({ name: :other_name, types: [:type2] })
      end

      it 'removes a predicate from the by_name hash' do
        predicate_registry.unregister(:name)
        expect(predicate_registry.instance_variable_get(:@by_name)).to match({ other_name: { name: :other_name, types: [:type2] }})
      end

      it 'removes a predicate from the by_type hash' do
        predicate_registry.unregister(:name)
        expect(predicate_registry.instance_variable_get(:@by_type)[:type1]).to match([])
        expect(predicate_registry.instance_variable_get(:@by_type)[:type2]).to match([{ name: :other_name, types: [:type2] }])
      end
    end

    describe '#apply_types_to_predicate' do
      before do
        predicate_registry.register({ name: :name, types: [:type1, :type2] })
      end

      it 'adds types to a predicate' do
        predicate_registry.apply_types_to_predicate(:name, :type3, :type4)
        expect(predicate_registry.instance_variable_get(:@by_name)[:name][:types]).to match([:type1, :type2, :type3, :type4])
        expect(predicate_registry.instance_variable_get(:@by_type)[:type3]).to match([{ name: :name, types: [:type1, :type2, :type3, :type4] }])
        expect(predicate_registry.instance_variable_get(:@by_type)[:type4]).to match([{ name: :name, types: [:type1, :type2, :type3, :type4] }])
      end
    end

    describe '#unregister_from_type' do
      before do
        predicate_registry.register({ name: :name, types: [:type1, :type2] })
        predicate_registry.register({ name: :other_name, types: [:type2] })
      end

      it 'removes a predicate from the by_type hash' do
        predicate_registry.unregister_from_type(:type2, :name)
        expect(predicate_registry.instance_variable_get(:@by_type)[:type1]).to match([{ name: :name, types: [:type1] }])
        expect(predicate_registry.instance_variable_get(:@by_type)[:type2]).to match([{ name: :other_name, types: [:type2] }])
      end
    end

    describe '#register_types' do
      it 'registers types with the type registry' do
        predicate_registry.register_types(:name, :type1, :type2)
        expect(predicate_registry.instance_variable_get(:@type_registry).instance_variable_get(:@by_group)[:name]).to match([:type1, :type2])
      end
    end

    describe '#unregister_types' do
      it 'unregisters types from the type registry' do
        predicate_registry.register_types(:name, :type1, :type2)
        predicate_registry.unregister_types(:name)
        expect(predicate_registry.instance_variable_get(:@type_registry).instance_variable_get(:@by_group)).to match(HashWithIndifferentAccess.new([]))
      end
    end

    describe '#unregister_types_from_group' do
      it 'unregisters types from a group in the type registry' do
        predicate_registry.register_types(:name, :type1, :type2)
        predicate_registry.unregister_types_from_group(:name, :type1)
        expect(predicate_registry.instance_variable_get(:@type_registry).instance_variable_get(:@by_group)[:name]).to match([:type2])
      end
    end

    describe '#by_name' do
      it 'returns a predicate by name' do
        predicate_registry.register({ name: :name, types: [:type1, :type2] })
        expect(predicate_registry.by_name(:name)).to match({ name: :name, types: [:type1, :type2] })
      end
    end

    describe '#by_type' do
      it 'returns a predicate by type' do
        predicate_registry.register({ name: :name, types: [:type1, :type2] })
        expect(predicate_registry.by_type(:type1)).to contain_exactly(:name)
        expect(predicate_registry.by_type(:type2)).to contain_exactly(:name)
      end
    end

    describe '#types' do
      it 'returns all types' do
        predicate_registry.register_types(:name, :type1, :type2)
        expect(predicate_registry.types).to eq([:all, :name, :type1, :type2])
      end
    end

    describe '#names' do
      it 'returns all names' do
        predicate_registry.register({ name: :name, types: [:type1, :type2] })
        expect(predicate_registry.names).to eq([:name])
      end
    end

    describe '#metadata_for' do
      before do
        predicate_registry.register({ name: :eq, types: [:numerical] })
        predicate_registry.register({ name: :between, types: [:numerical] })
      end

      it 'returns normalized metadata fields for a raw registry definition' do
        metadata = predicate_registry.metadata_for(:eq, locale: :en)
        expect(metadata).to be_a(Hash)
        expect(metadata).to have_key(:label)
        expect(metadata).to include(:parameters, :arguments)
        expect(metadata[:parameters]).to be_nil
        expect(metadata[:arguments]).to eq({ min: nil, max: nil })
      end

      it 'returns translated label from i18n' do
        metadata = predicate_registry.metadata_for(:eq, locale: :en)
        expect(metadata[:label]).to eq('equals')
      end

      it 'does not invent a signature for a raw registry definition' do
        metadata = predicate_registry.metadata_for(:between, locale: :en)
        expect(metadata[:parameters]).to be_nil
        expect(metadata[:arguments]).to eq({ min: nil, max: nil })
      end

      it 'falls back to humanized name when translation is missing' do
        predicate_registry.register({ name: :custom_predicate, types: [:all] })
        metadata = predicate_registry.metadata_for(:custom_predicate, locale: :en)
        expect(metadata[:label]).to eq('custom predicate')
      end

      it 'returns nil for non-existent predicate' do
        metadata = predicate_registry.metadata_for(:nonexistent, locale: :en)
        expect(metadata).to be_nil
      end
    end

    describe '#metadata_hash' do
      before do
        predicate_registry.register({ name: :eq, types: [:numerical] })
        predicate_registry.register({ name: :gt, types: [:numerical] })
        predicate_registry.register({ name: :lt, types: [:numerical] })
      end

      it 'returns hash of metadata for multiple predicates' do
        metadata = predicate_registry.metadata_hash([:eq, :gt, :lt], locale: :en)
        expect(metadata).to be_a(Hash)
        expect(metadata.keys).to match_array([:eq, :gt, :lt])
      end

      it 'each predicate has normalized signature metadata' do
        metadata = predicate_registry.metadata_hash([:eq, :gt], locale: :en)
        expect(metadata[:eq]).to have_key(:label)
        expect(metadata[:eq]).to include(:parameters, :arguments)
        expect(metadata[:gt]).to have_key(:label)
        expect(metadata[:gt]).to include(:parameters, :arguments)
      end

      it 'returns translated labels for all predicates' do
        metadata = predicate_registry.metadata_hash([:eq, :gt, :lt], locale: :en)
        expect(metadata[:eq][:label]).to eq('equals')
        expect(metadata[:gt][:label]).to eq('greater than')
        expect(metadata[:lt][:label]).to eq('less than')
      end

      it 'handles empty array' do
        metadata = predicate_registry.metadata_hash([], locale: :en)
        expect(metadata).to eq({})
      end
    end
  end