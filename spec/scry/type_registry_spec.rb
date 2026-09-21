require 'rails_helper'

RSpec.describe Scry::TypeRegistry do
    let(:type_registry) { Scry::TypeRegistry.new }

    describe '#initialize' do
      it 'initializes the by_name instance variable' do
        expect(type_registry.instance_variable_get(:@by_group)).to eq(HashWithIndifferentAccess.new([]))
      end
    end

    describe '#register' do
      it 'adds types to the by_group hash' do
        type_registry.register(:name, :type1, :type2)
        expect(type_registry.instance_variable_get(:@by_group)[:name]).to eq([:type1, :type2])
      end
    end

    describe '#unregister' do
      it 'removes group from the by_group hash' do
        type_registry.register(:name, :type1, :type2)
        type_registry.unregister(:name)
        expect(type_registry.instance_variable_get(:@by_group)).to eq(HashWithIndifferentAccess.new([]))
      end

      it 'removes a leaf type symbol from all groups when given' do
        type_registry.register(:group1, :type1, :type2, :common)
        type_registry.register(:group2, :type3, :common)
        type_registry.register(:group3, :type4, :common)

        type_registry.unregister(:common)

        expect(type_registry.instance_variable_get(:@by_group)[:group1]).to eq([:type1, :type2])
        expect(type_registry.instance_variable_get(:@by_group)[:group2]).to eq([:type3])
        expect(type_registry.instance_variable_get(:@by_group)[:group3]).to eq([:type4])
      end

      it 'removes multiple leaf type symbols from all groups when given' do
        type_registry.register(:group1, :type1, :type2, :common1, :common2)
        type_registry.register(:group2, :type3, :common1)
        type_registry.register(:group3, :type4, :common2)

        type_registry.unregister(:common1, :common2)

        expect(type_registry.instance_variable_get(:@by_group)[:group1]).to eq([:type1, :type2])
        expect(type_registry.instance_variable_get(:@by_group)[:group2]).to eq([:type3])
        expect(type_registry.instance_variable_get(:@by_group)[:group3]).to eq([:type4])
      end
    end

    describe '#unregister_from_group' do
      it 'removes types from a group' do
        type_registry.register(:name, :type1, :type2)
        type_registry.unregister_from_group(:name, :type1)
        expect(type_registry.instance_variable_get(:@by_group)[:name]).to eq([:type2])
      end
    end

    describe '#by_group' do
      let(:name) { :name }

      before do
        type_registry.register(:name, :type1, :type2)
      end

      it 'returns all types for a group' do
        expect(type_registry.by_group(name)).to eq([:all, :name, :type1, :type2])
      end

      context 'when the group is :all' do
        let(:name) { :all }
        before do
          type_registry.register(:test, :type3)
        end

        it 'returns all types for all groups' do
          expect(type_registry.by_group(name)).to eq([:all, :name, :type1, :type2, :test, :type3])
        end
      end

      context 'when the type is a part of parent groups' do
        before do
          type_registry.register(:parent0, :name, :type4)
          type_registry.register(:parent1, :name, :type5)
          type_registry.register(:parent01, :parent0)
          type_registry.register(:parent11, :parent1)
          type_registry.register(:test, :type3)

          type_registry.register(:testing, :type6)
        end

        it 'returns all the parent groups' do
          expect(type_registry.by_group(name)).to eq([:all, :parent01, :parent11, :parent0, :parent1, :name, :type1, :type2])
        end
      end

      context 'when the type is a parent group' do
        before do
          type_registry.register(:name, :child1, :child2)
          type_registry.register(:child1, :type3, :type4)
          type_registry.register(:child2, :type4, :type5)

          type_registry.register(:testing, :type6)
        end

        it 'returns all the parent groups' do
          expect(type_registry.by_group(name)).to eq([:all, :name, :type1, :type2, :child1, :type3, :type4, :child2, :type5])
        end
      end
    end
  end
