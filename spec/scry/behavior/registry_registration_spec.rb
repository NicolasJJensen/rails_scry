# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round14' + ' - ' + 'Filterable.get_block' do
  describe 'Filterable.get_block' do
    it 'raises ArgumentError when both function and block are given' do
      expect {
        User.send(:get_block, :some_method) { |_| 'block' }
      }.to raise_error(ArgumentError, /both a block and a function/)
    end

    it 'raises ArgumentError when neither function nor block is given' do
      expect {
        User.send(:get_block)
      }.to raise_error(ArgumentError, /no block or function/)
    end
  end

  # ── 2. Configuration.register_predicate warning paths ────────────────────────
end

RSpec.describe 'round14' + ' - ' + 'Configuration.register_predicate warnings' do
  describe 'Configuration.register_predicate warnings' do
    after(:each) do
      Scry.configuration.predicate_registry.unregister(
        :test_both, :test_both_any, :test_both_all,
        :test_custom_compound, :test_custom_compound_any, :test_custom_compound_all,
        :totally_fake_not_real, :totally_fake_not_real_any, :totally_fake_not_real_all
      )
    end

    it 'fails when both arel_predicate and block are given' do
      expect { Scry.configuration.register_predicate(
        :test_both, types: [:all], arel_predicate: :eq, compounds: false
      ) { |attr, val| attr.eq(val) } }.to raise_error(ArgumentError, /both/)
    end

    it 'generates compound variants when block provided without arel_predicate' do
      Scry.configuration.register_predicate(
        :test_custom_compound, types: [:all], compounds: true
      ) { |attr, val| attr.eq(val) }
      registry = Scry.configuration.predicate_registry
      expect(registry.by_name(:test_custom_compound_any)).to be_present
      expect(registry.by_name(:test_custom_compound_all)).to be_present
    end

    it 'fails when predicate name is not a valid arel predicate and no block given' do
      expect { Scry.configuration.register_predicate(
        :totally_fake_not_real, types: [:all]
      ) }.to raise_error(ArgumentError, /unknown Arel predicate/)
    end
  end
end
