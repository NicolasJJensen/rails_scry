require 'rails_helper'

RSpec.describe 'Scry.filter_records_by with scoped relations' do
  let!(:org_a) { create(:organisation, name: 'Org A') }
  let!(:org_b) { create(:organisation, name: 'Org B') }
  let!(:alice) { create(:user, first_name: 'Alice', last_name: 'Smith', organisation: org_a) }
  let!(:bob)   { create(:user, first_name: 'Bob', last_name: 'Jones', organisation: org_a) }
  let!(:carol) { create(:user, first_name: 'Carol', last_name: 'Smith', organisation: org_b) }

  describe 'input validation' do
    it 'raises ArgumentError for a string' do
      expect {
        Scry.filter_records_by(records: 'not_a_model', filter: {}, context: nil).relation
      }.to raise_error(ArgumentError, /records must either be/)
    end

    it 'raises ArgumentError for an integer' do
      expect {
        Scry.filter_records_by(records: 42, filter: {}, context: nil).relation
      }.to raise_error(ArgumentError, /records must either be/)
    end

    it 'raises ArgumentError for a non-ActiveRecord class' do
      expect {
        Scry.filter_records_by(records: String, filter: {}, context: nil).relation
      }.to raise_error(ArgumentError, /records must either be/)
    end
  end

  describe 'bare class (backward compat)' do
    it 'works the same as the old filter_model_by' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result.map(&:first_name)).to eq(['Alice'])
    end
  end

  describe 'scoped relation' do
    it 'only returns records within the scope' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'last_name', predicate: 'eq', args: ['Smith'] }
        ]
      }

      # Both Alice (org_a) and Carol (org_b) have last_name Smith
      # Scoping to org_a should only return Alice
      result = Scry.filter_records_by(
        records: User.where(organisation: org_a),
        filter: filter,
        context: nil
      ).relation

      expect(result.map(&:first_name)).to eq(['Alice'])
    end

    it 'returns empty when scope excludes all matches' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Carol'] }
        ]
      }

      # Carol is in org_b, scoping to org_a returns nothing
      result = Scry.filter_records_by(
        records: User.where(organisation: org_a),
        filter: filter,
        context: nil
      ).relation

      expect(result).to be_empty
    end
  end

  describe 'group OR with scope' do
    it 'combines OR conditions while respecting the scope' do
      filter = {
        type: 'group', predicate: 'or', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Carol'] }
        ]
      }

      # Without scope: both Alice and Carol match
      all_result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(all_result.map(&:first_name).sort).to eq(['Alice', 'Carol'])

      # With org_a scope: only Alice matches
      scoped_result = Scry.filter_records_by(
        records: User.where(organisation: org_a),
        filter: filter,
        context: nil
      ).relation
      expect(scoped_result.map(&:first_name)).to eq(['Alice'])
    end
  end

  describe 'negation with scope' do
    it 'negates within the scope' do
      filter = {
        type: 'group', predicate: 'and', negate: true, filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        ]
      }

      # Negate "first_name = Alice" within org_a scope → Bob
      result = Scry.filter_records_by(
        records: User.where(organisation: org_a),
        filter: filter,
        context: nil
      ).relation

      expect(result.map(&:first_name)).to eq(['Bob'])
    end
  end

  describe 'association filter with scope' do
    let!(:email_a) { create(:email, address: 'alice@example.com') }
    let!(:email_b) { create(:email, address: 'bob@example.com') }

    before do
      alice.emails << email_a
      bob.emails << email_b
      carol.emails << email_a
    end

    it 'applies association filter within the scoped relation' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'emails', predicate: 'has_any', args: [[email_a.id]] }
        ]
      }

      # Alice (org_a) and Carol (org_b) both have email_a
      # Scoping to org_a should only return Alice
      result = Scry.filter_records_by(
        records: User.where(organisation: org_a),
        filter: filter,
        context: nil
      ).relation

      expect(result.map(&:first_name)).to eq(['Alice'])
    end
  end

  describe 'aggregate filter with scope' do
    before do
      2.times { alice.emails << create(:email) }
      1.times { bob.emails << create(:email) }
      3.times { carol.emails << create(:email) }
    end

    it 'applies aggregate filter within the scoped relation' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gteq', args: [2] }
        ]
      }

      # Alice has 2 emails, Carol has 3 — both pass count >= 2
      # Scoping to org_a should only return Alice
      result = Scry.filter_records_by(
        records: User.where(organisation: org_a),
        filter: filter,
        context: nil
      ).relation

      expect(result.map(&:first_name)).to eq(['Alice'])
    end
  end

  describe 'ordering and limit stripping' do
    it 'strips order before filtering and reapplies after' do
      filter = {
        type: 'group', predicate: 'or', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Bob'] }
        ]
      }

      result = Scry.filter_records_by(
        records: User.where(organisation: org_a).order(first_name: :desc),
        filter: filter,
        context: nil
      ).relation

      expect(result.map(&:first_name)).to eq(['Bob', 'Alice'])
    end

    it 'strips limit before filtering and reapplies after' do
      filter = {
        type: 'group', predicate: 'or', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Bob'] }
        ]
      }

      result = Scry.filter_records_by(
        records: User.where(organisation: org_a).order(:first_name).limit(1),
        filter: filter,
        context: nil
      ).relation

      # Org A has Alice and Bob; limit(1) reapplied after filtering
      expect(result.count).to eq(1)
      expect(result.first.first_name).to eq('Alice')
    end

    it 'strips offset before filtering and reapplies after' do
      filter = {
        type: 'group', predicate: 'or', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Bob'] }
        ]
      }

      result = Scry.filter_records_by(
        records: User.where(organisation: org_a).order(:first_name).offset(1),
        filter: filter,
        context: nil
      ).relation

      # Org A: Alice, Bob (ordered). Offset(1) skips Alice → Bob
      expect(result.map(&:first_name)).to eq(['Bob'])
    end
  end

  describe 'scope with joins and complex conditions' do
    it 'preserves join-based WHERE conditions' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        ]
      }

      # Scope via join: users whose organisation is named 'Org A'
      scoped = User.joins(:organisation).where(organisations: { name: 'Org A' })

      result = Scry.filter_records_by(
        records: scoped,
        filter: filter,
        context: nil
      ).relation

      expect(result.map(&:first_name)).to eq(['Alice'])
    end
  end
end
