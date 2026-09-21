require 'rails_helper'

RSpec.describe 'Filter Negation' do

  describe 'Property filter negation' do
    it 'negates a simple property filter' do
      u1 = create(:user, first_name: 'Alice')
      u2 = create(:user, first_name: 'Bob')

      filter = {
        type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'], negate: true
      }

      result = Scry.filter_records_by(records: User.where(id: [u1.id, u2.id]), filter: { type: 'group', predicate: 'and', filters: [filter] }, context: nil).relation
      expect(result).to match_array([u2])
    end
  end

  describe 'Group filter negation' do
    it 'negates a group with OR predicate' do
      u1 = create(:user, first_name: 'Eve')
      u2 = create(:user, first_name: 'Evan')
      u3 = create(:user, first_name: 'Mallory')

      inner = {
        type: 'group', predicate: 'or', negate: true, filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Eve'] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Evan'] }
        ]
      }

      result = Scry.filter_records_by(records: User.where(id: [u1.id, u2.id, u3.id]), filter: { type: 'group', predicate: 'and', filters: [inner] }, context: nil).relation
      expect(result).to match_array([u3])
    end

    it 'negates a group with AND predicate' do
      u1 = create(:user, first_name: 'John', last_name: 'Doe')
      u2 = create(:user, first_name: 'John', last_name: 'Smith')
      u3 = create(:user, first_name: 'Jane', last_name: 'Doe')

      inner = {
        type: 'group', predicate: 'and', negate: true, filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['John'] },
          { type: 'property', property: 'last_name', predicate: 'eq', args: ['Doe'] }
        ]
      }

      result = Scry.filter_records_by(records: User.where(id: [u1.id, u2.id, u3.id]), filter: { type: 'group', predicate: 'and', filters: [inner] }, context: nil).relation
      expect(result).to match_array([u2, u3])
    end
  end

  describe 'Association filter negation' do
    it 'negates an association filter' do
      org1 = create(:organisation)
      org2 = create(:organisation)

      u1 = create(:user, organisation: org1)
      u2 = create(:user, organisation: org2)

      filter = {
        type: 'association', association: 'organisation', predicate: 'has_any', args: [[org1.id]], negate: true
      }

      result = Scry.filter_records_by(records: User.where(id: [u1.id, u2.id]), filter: { type: 'group', predicate: 'and', filters: [filter] }, context: nil).relation
      expect(result).to match_array([u2])
    end
  end

  describe 'SQL generation efficiency' do
    it 'uses direct NOT instead of NOT IN subquery' do
      u1 = create(:user, first_name: 'Alice')
      u2 = create(:user, first_name: 'Bob')

      filter = {
        type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'], negate: true
      }

      result = Scry.filter_records_by(records: User.where(id: [u1.id, u2.id]), filter: { type: 'group', predicate: 'and', filters: [filter] }, context: nil).relation

      # Verify it uses direct NOT, not NOT IN
      sql = result.to_sql
      expect(sql).to include('NOT (')
      expect(sql).not_to include('NOT IN')

      # Verify correct results
      expect(result).to match_array([u2])
    end
  end

  describe 'Aggregate filter negation' do
    def user_with_emails(addresses)
      user = create(:user, emails_count: 0)
      addresses.each { |addr| user.emails << create(:email, address: addr) }
      user
    end

    it 'negates an aggregate count filter' do
      u1 = user_with_emails(%w[a@x.com b@x.com c@x.com])
      u2 = user_with_emails(%w[one@x.com])

      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [2], negate: true
      }

      result = Scry.filter_records_by(records: User, filter: { type: 'group', predicate: 'and', filters: [filter] }, context: nil).relation
      scoped = result.where(id: [u1.id, u2.id])
      expect(scoped).to match_array([u2])
    end
  end

  describe 'Nested negation' do
    it 'handles negated group containing negated property' do
      u1 = create(:user, first_name: 'Alice', last_name: 'Smith')
      u2 = create(:user, first_name: 'Bob', last_name: 'Jones')
      u3 = create(:user, first_name: 'Alice', last_name: 'Jones')

      # NOT(first_name != 'Alice' AND last_name = 'Jones')
      # = NOT(first_name != 'Alice') OR NOT(last_name = 'Jones')
      # = first_name = 'Alice' OR last_name != 'Jones'
      # Should match: Alice/Smith, Alice/Jones (has Alice), and NOT Bob/Jones
      inner = {
        type: 'group', predicate: 'and', negate: true, filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'], negate: true },
          { type: 'property', property: 'last_name', predicate: 'eq', args: ['Jones'] }
        ]
      }

      result = Scry.filter_records_by(records: User.where(id: [u1.id, u2.id, u3.id]), filter: { type: 'group', predicate: 'and', filters: [inner] }, context: nil).relation
      expect(result).to match_array([u1, u3])
    end
  end
end
