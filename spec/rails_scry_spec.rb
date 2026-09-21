require 'rails_helper'

RSpec.describe Scry do
  let(:freeze_time) { Time.utc(2010, 1, 1, 1) }
  around do |example|
    Timecop.freeze(freeze_time) do
      example.run
    end
  end

  describe 'self.filter_records_by' do
    before(:context) do
      User.destroy_all
      Email.destroy_all
      Phone.destroy_all
      Account.destroy_all
      Organisation.destroy_all

      @organisation1 = FactoryBot.create(:organisation)
      @organisation2 = FactoryBot.create(:organisation)
      @organisation3 = FactoryBot.create(:organisation)
      @user1 = FactoryBot.create(:user, first_name: 'John', date_of_birth: Date.new(1990, 1, 1), organisation: @organisation1)
      @user2 = FactoryBot.create(:user, first_name: 'Jane', date_of_birth: Date.new(1990, 1, 1), organisation: @organisation1)
      @user3 = FactoryBot.create(:user, first_name: 'James', date_of_birth: Date.new(2001, 1, 1), organisation: @organisation2)
      @user4 = FactoryBot.create(:user, first_name: 'Nic', date_of_birth: Date.new(1992, 1, 1), organisation: @organisation2)
      @user5 = FactoryBot.create(:user, first_name: 'Nicolas', date_of_birth: Date.new(2001, 1, 1), organisation: @organisation3)
    end

    let(:value) { [] }
    let(:type) { 'group' }
    let(:predicate) { 'and' }
    let(:filter) do
      {
        type: type,
        predicate: predicate,
        filters: value
      }
    end

    context 'when using nested group filters' do
      let(:value) do
        [
          {
            type: 'group',
            predicate: 'or',
            filters: [
              {
                type: 'property',
                property: 'first_name',
                predicate: 'starts_with',
                args: ['N']
              },
              {
                type: 'property',
                property: 'first_name',
                predicate: 'starts_with',
                args: ['J']
              }
            ]
          },
          {
            type: 'group',
            predicate: 'or',
            filters: [
              {
                type: 'property',
                property: 'date_of_birth',
                predicate: 'gt',
                args: [Date.new(2000, 1, 1)]
              },
              {
                type: 'property',
                property: 'date_of_birth',
                predicate: 'lt',
                args: [Date.new(1991, 1, 1)]
              },
            ]
          }
        ]
      end

      it 'combines the filters correctly' do
        result = Scry.filter_records_by(
          records: User,
          filter: filter,
          context: nil
        ).relation

        expect(result).to match_array([@user1, @user2, @user3, @user5])
      end
    end

    context 'when using an or filter' do
      let(:predicate) { 'or' }
      let(:value) do
        [
          {
            type: 'property',
            property: 'date_of_birth',
            predicate: 'lt',
            args: [Date.new(2000, 1, 1)]
          },
          {
            type: 'property',
            property: 'first_name',
            predicate: 'starts_with',
            args: ['N']
          }
        ]
      end

      it 'correctly filters model' do
        result = Scry.filter_records_by(
          records: User,
          filter: filter,
          context: nil
        ).relation

        expect(result).to match_array([@user1, @user2, @user4, @user5])
      end

      context 'when using nested group filters' do
        let(:value) do
          [
            {
              type: 'group',
              predicate: 'and',
              filters: [
                {
                  type: 'property',
                  property: 'date_of_birth',
                  predicate: 'lt',
                  args: [Date.new(2000, 1, 1)]
                },
                {
                  type: 'property',
                  property: 'first_name',
                  predicate: 'starts_with',
                  args: ['J']
                }
              ]
            },
            {
              type: 'group',
              predicate: 'and',
              filters: [
                {
                  type: 'property',
                  property: 'date_of_birth',
                  predicate: 'gt',
                  args: [Date.new(2000, 1, 1)]
                },
                {
                  type: 'property',
                  property: 'first_name',
                  predicate: 'starts_with',
                  args: ['N']
                }
              ]
            }
          ]
        end

        it 'combines the filters correctly' do
          result = Scry.filter_records_by(
            records: User,
            filter: filter,
            context: nil
          ).relation

          expect(result).to match_array([@user1, @user2, @user5])
        end
      end
    end

    context 'when filtering by property' do
      let(:attribute) { nil }
      # Keep group-level predicate as 'and' for a single subfilter
      let(:predicate) { 'and' }
      # Property-level predicate and value
      let(:prop_predicate) { nil }
      let(:arg_value) { nil }
      let(:value) do
        [
          {
            type: 'property',
            property: attribute,
            predicate: prop_predicate,
            args: [arg_value]
          }
        ]
      end

      context 'integer attribute' do
        let(:attribute) { 'id' }
        let(:prop_predicate) { 'gt' }
        let(:arg_value) { 0 }

        it 'correctly filters model' do
          result = Scry.filter_records_by(
            records: User,
            filter: filter,
            context: nil
          ).relation

          expect(result).to match_array([@user1, @user2, @user3, @user4, @user5])
        end
      end

      context 'decimal attribute' do
        let(:attribute) { 'cost' }
        let(:prop_predicate) { 'gt' }
        let(:arg_value) { 50.5 }

        it 'correctly filters model' do
          org = FactoryBot.create(:organisation)
          a1 = FactoryBot.create(:asset, organisation: org, cost: 100)
          a2 = FactoryBot.create(:asset, organisation: org, cost: 75.25)
          a3 = FactoryBot.create(:asset, organisation: org, cost: 51)
          _a4 = FactoryBot.create(:asset, organisation: org, cost: 49.99)

          result = Scry.filter_records_by(
            records: Asset,
            filter: filter,
            context: nil
          ).relation

          expect(result).to match_array([a1, a2, a3])
        end
      end

      context 'date attribute' do
        let(:attribute) { 'date_of_birth' }
        let(:prop_predicate) { 'lt' }
        let(:arg_value) { Date.new(2000, 1, 1) }

        it 'correctly filters model' do
          result = Scry.filter_records_by(
            records: User,
            filter: filter,
            context: nil
          ).relation

          expect(result).to match_array([@user1, @user2, @user4])
        end
      end

      context 'datetime attribute' do
        let(:attribute) { 'created_at' }
        let(:prop_predicate) { 'gt' }
        let(:arg_value) { Time.utc(2000, 1, 1, 0) }

        it 'correctly filters model' do
          result = Scry.filter_records_by(
            records: User,
            filter: filter,
            context: nil
          ).relation

          expect(result).to match_array([@user1, @user2, @user3, @user4, @user5])
        end
      end

      context 'string attribute' do
        let(:attribute) { 'first_name' }
        let(:prop_predicate) { 'starts_with' }
        let(:arg_value) { 'J' }

        it 'correctly filters model' do
          result = Scry.filter_records_by(
            records: User,
            filter: filter,
            context: nil
          ).relation

          expect(result).to match_array([@user1, @user2, @user3])
        end
      end

      context 'text attribute' do
        let(:attribute) { 'description' }
        let(:prop_predicate) { 'matches' }
        let(:arg_value) { 'test' }

        it 'correctly filters model' do
          org = FactoryBot.create(:organisation)
          a1 = FactoryBot.create(:asset, organisation: org, description: 'A test asset')
          a2 = FactoryBot.create(:asset, organisation: org, description: 'Another test item')
          _a3 = FactoryBot.create(:asset, organisation: org, description: 'No match here')

          result = Scry.filter_records_by(
            records: Asset,
            filter: filter,
            context: nil
          ).relation

          expect(result).to match_array([a1, a2])
        end
      end
    end

    context 'when filtering by multiple attributes' do
      let(:value) do
        [
          {
            type: 'property',
            property: 'date_of_birth',
            predicate: 'lt',
            args: [Date.new(2000, 1, 1)]
          },
          {
            type: 'property',
            property: 'first_name',
            predicate: 'matches',
            args: ['J']
          }
        ]
      end

      it 'correctly filters model' do
        result = Scry.filter_records_by(
          records: User,
          filter: filter,
          context: nil
        ).relation

        expect(result).to match_array([@user1, @user2])
      end
    end

    context 'when filtering by association' do
      let(:association) { nil }
      let(:association_value) { nil }
      let(:association_predicate) { nil }
      let(:value) do
        [
          {
            type: 'association',
            association: association,
            predicate: association_predicate,
            args: [association_value]
          }
        ]
      end

      context 'when filtering by a belongs_to association' do
        let(:association) { 'organisation' }

        context 'when filtering by predicate with single value' do
          let(:association_value) { [@user1.organisation.id] }
          let(:association_predicate) { 'has_any' }

          it 'correctly filters model' do
            result = Scry.filter_records_by(
              records: User,
              filter: filter,
              context: nil
            ).relation

            expect(result).to match_array([@user1, @user2])
          end
        end

        context 'when filtering by predicate with multiple values' do
          let(:association_value) { [@organisation1.id, @organisation2.id] }
          let(:association_predicate) { 'has_any' }

          it 'correctly filters model' do
            result = Scry.filter_records_by(
              records: User,
              filter: filter,
              context: nil
            ).relation

            expect(result).to match_array([@user1, @user2, @user3, @user4])
          end
        end
      end

    end
  end
end

RSpec.describe 'Scry end-to-end complex filter' do
  it 'combines properties, associations, groups, and negation correctly' do
    org1 = create(:organisation)
    org2 = create(:organisation)

    u1 = create(:user, first_name: 'Alice', organisation: org1)
    u2 = create(:user, first_name: 'Bob',   organisation: org1)
    _u3 = create(:user, first_name: 'Eve',  organisation: org2)

    # Complex filter:
    # (first_name == 'Alice' OR first_name == 'Bob')
    # AND organisation == org1
    # AND NOT (first_name == 'Eve')
    filter = {
      type: 'group', predicate: 'and', filters: [
        {
          type: 'group', predicate: 'or', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] },
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Bob'] }
          ]
        },
        { type: 'association', association: 'organisation', predicate: 'has_any', args: [[org1.id]] },
        { type: 'property', property: 'first_name', predicate: 'eq', args: ['Eve'], negate: true }
      ]
    }

    result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
    expect(result).to match_array([u1, u2])
  end
end
