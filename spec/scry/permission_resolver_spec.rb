require 'rails_helper'

RSpec.describe Scry::PermissionResolver do
  def perm(list_type, items)
    { list_type: list_type, block: ->(_ctx) { items } }
  end

  describe '.reduce' do
    it 'whitelist filters to intersection' do
      result = described_class.reduce(
        [:a, :b, :c, :d],
        permissions: [perm(:whitelist, [:b, :c])],
        context: nil
      )
      expect(result).to match_array([:b, :c])
    end

    it 'blacklist removes items' do
      result = described_class.reduce(
        [:a, :b, :c, :d],
        permissions: [perm(:blacklist, [:b, :d])],
        context: nil
      )
      expect(result).to match_array([:a, :c])
    end

    it 'includelist adds items constrained by universe' do
      result = described_class.reduce(
        [:a],
        permissions: [perm(:includelist, [:b, :c, :z])],
        context: nil,
        universe: [:a, :b, :c]
      )
      expect(result).to match_array([:a, :b, :c])
      expect(result).not_to include(:z)
    end

    it 'excludelist removes items' do
      result = described_class.reduce(
        [:a, :b, :c, :d],
        permissions: [perm(:excludelist, [:a, :c])],
        context: nil
      )
      expect(result).to match_array([:b, :d])
    end

    it 'chains multiple operations in order' do
      result = described_class.reduce(
        [:a, :b, :c, :d, :e],
        permissions: [
          perm(:blacklist, [:e]),       # remove :e -> [:a,:b,:c,:d]
          perm(:whitelist, [:a, :b, :c]), # keep only intersection -> [:a,:b,:c]
          perm(:excludelist, [:a])      # remove :a -> [:b,:c]
        ],
        context: nil
      )
      expect(result).to match_array([:b, :c])
    end

    it 'propagates NameError from permission block' do
      bad_perm = { list_type: :whitelist, block: ->(_ctx) { raise NameError, 'undefined Foo' } }

      expect {
        described_class.reduce([:a], permissions: [bad_perm], context: nil)
      }.to raise_error(NameError, /Foo/)
    end

    it 're-raises StandardError from permission block' do
      bad_perm = { list_type: :whitelist, block: ->(_ctx) { raise RuntimeError, 'boom' } }

      expect {
        described_class.reduce([:a], permissions: [bad_perm], context: nil)
      }.to raise_error(RuntimeError, 'boom')
    end

    it 'raises FilterError for unrecognized list_type' do
      bad_perm = { list_type: :unknown_type, block: ->(_ctx) { [:a] } }

      expect {
        described_class.reduce([:a], permissions: [bad_perm], context: nil)
      }.to raise_error(Scry::FilterError, /unrecognized list_type/)
    end

    it 'returns initial when no permissions are given' do
      result = described_class.reduce(
        [:a, :b, :c],
        permissions: [],
        context: nil
      )
      expect(result).to match_array([:a, :b, :c])
    end
  end
end
