# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round10' + ' - ' + 'Association predicate empty set edge cases' do
  describe 'Association predicate empty set edge cases' do
    let!(:org) { create(:organisation) }
    let!(:u1) { create(:user, organisation: org, emails_count: 1) }
    let!(:u2) { create(:user, organisation: org, emails_count: 0) }

    it 'has_any([]) returns no records (vacuous falsehood)' do
      filter = {
        type: 'association', association: 'emails', predicate: 'has_any', args: [[]]
      }

      result = Scry.filter_records_by(
        records: User.where(id: [u1.id, u2.id]),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      expect(result).to be_empty
    end

    it 'has_all([]) returns all records (vacuous truth)' do
      filter = {
        type: 'association', association: 'emails', predicate: 'has_all', args: [[]]
      }

      result = Scry.filter_records_by(
        records: User.where(id: [u1.id, u2.id]),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      expect(result).to match_array([u1, u2])
    end

    it 'only_has_all([]) returns all records (vacuous truth)' do
      filter = {
        type: 'association', association: 'emails', predicate: 'only_has_all', args: [[]]
      }

      result = Scry.filter_records_by(
        records: User.where(id: [u1.id, u2.id]),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      expect(result).to match_array([u1, u2])
    end
  end

  # ── 5.2 Negation + aggregate combos ────────────────────────────────────────
end

RSpec.describe 'round10' + ' - ' + 'Negation + aggregate combinations' do
  describe 'Negation + aggregate combinations' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        example.run
      end
    end

    def user_with_emails(addresses)
      user = create(:user, emails_count: 0)
      addresses.each { |addr| user.emails << create(:email, address: addr) }
      user
    end

    it 'negates an aggregate count with natural zero-count' do
      u1 = user_with_emails(%w[a@x.com b@x.com c@x.com])
      u2 = user_with_emails([])
      u3 = user_with_emails(%w[one@x.com])

      # Count emails >= 2, negated: exclude users with 2+ emails
      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'gteq', args: [2], negate: true
      }

      # Use unscoped User (same pattern as existing negation_spec.rb) since
      # aggregate negation operates via JOINs, not WHERE clauses
      result = Scry.filter_records_by(
        records: User,
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      scoped = result.where(id: [u1.id, u2.id, u3.id])
      # u1 has 3 emails (count >= 2 is true, negated = excluded)
      # u2 has 0 emails (count >= 2 is false via include_zero LEFT JOIN, negated = included)
      # u3 has 1 email (count >= 2 is false, negated = included)
      expect(scoped).to match_array([u2, u3])
    end

    it 'negates aggregate count == 0 with NOT EXISTS optimization' do
      u1 = user_with_emails([])
      u2 = user_with_emails(%w[a@x.com b@x.com])

      # Count == 0 with natural zero-count triggers NOT EXISTS optimization
      # Negating it means: users who DO have emails
      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'eq', args: [0], negate: true,
        scoping: {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'id', predicate: 'gteq', args: [0] }
          ]
        }
      }

      result = Scry.filter_records_by(
        records: User.where(id: [u1.id, u2.id]),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      expect(result).to match_array([u2])
    end
  end

  # ── 5.3 R10 fix tests ─────────────────────────────────────────────────────
end

RSpec.describe 'round10' + ' - ' + 'Predicate registry metadata immutability' do
  describe 'Predicate registry metadata immutability' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        example.run
      end
    end

    it 'prevents mutation of registered predicate metadata' do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :immutable_pred,
        arel_predicate: :eq,
        types: [:all]
      })

      predicate = Scry.configuration.predicate_registry.by_name(:immutable_pred)

      expect(predicate).to be_frozen
      expect { predicate[:types] = [] }.to raise_error(FrozenError)
    end
  end
end

RSpec.describe 'round10' + ' - ' + 'base.rb custom_predicate nil guard' do
  describe 'base.rb custom_predicate nil guard' do
    after(:each) do
      Scry.configuration.predicate_registry.unregister(:broken_pred)
    end

    before(:each) do
      Scry.configuration.predicate_registry.register({parameters: [{name: :value, kind: :required}], arguments: {min: 1, max: 1}, 
        name: :broken_pred,
        arel_predicate: nil,
        custom_predicate: nil,
        types: [:all]
      })
    end

    it 'raises FilterError when predicate has no arel_predicate or custom_predicate under :raise policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise

        u1 = create(:user)
        filter = {
          type: 'property', property: 'first_name', predicate: 'broken_pred', args: ['test']
        }

        expect {
          Scry.filter_records_by(
            records: User.where(id: u1.id),
            filter: { type: 'group', predicate: 'and', filters: [filter] },
            context: nil
          ).relation
        }.to raise_error(Scry::FilterError, /has no arel_predicate or custom_predicate/)
      end
    end

    it 'warns when predicate has no arel_predicate or custom_predicate with diagnostic logging enabled' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn

        u1 = create(:user)
        filter = {
          type: 'property', property: 'first_name', predicate: 'broken_pred', args: ['test']
        }

        expect(Rails.logger).to receive(:warn) do |payload|
          event = JSON.parse(payload)
          expect(event).to include(
            'code' => 'invalid_filter',
            'message' => 'Scry: predicate :broken_pred has no arel_predicate or custom_predicate'
          )
        end

        result = Scry.filter_records_by(
          records: User.where(id: u1.id),
          filter: { type: 'group', predicate: 'and', filters: [filter] },
          context: nil
        ).relation
        # Group with single failing child, filter_records_by returns original records
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end

    it 'returns original records silently under :skip policy when predicate has neither' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :skip

        u1 = create(:user)
        filter = {
          type: 'property', property: 'first_name', predicate: 'broken_pred', args: ['test']
        }

        result = Scry.filter_records_by(
          records: User.where(id: u1.id),
          filter: { type: 'group', predicate: 'and', filters: [filter] },
          context: nil
        ).relation
        # Group with single failing child, filter_records_by returns original records
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end
  end
end

RSpec.describe 'round10' + ' - ' + 'Aggregate scoping nil returns handle_error' do
  describe 'Aggregate scoping nil returns handle_error' do
    it 'calls handle_error when scoping returns nil for non-include_zero aggregate' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn

        u1 = create(:user, emails_count: 1)

        # Build an aggregate with scoping that returns nil (missing :predicate key)
        filter = {
          type: 'aggregate', association: 'emails', aggregate: 'count',
          predicate: 'eq', args: [1],
          scoping: {
            type: 'group', filters: [
              { type: 'property', property: 'address', predicate: 'eq', args: ['x'] }
            ]
          }
        }

        expect(Rails.logger).to receive(:warn) do |payload|
          event = JSON.parse(payload)
          expect(event).to include(
            'source' => 'Scry',
            'category' => 'invalid_filter',
            'code' => 'missing_predicate',
            'message' => 'Scry: group filter has missing :predicate key'
          )
        end

        result = Scry.filter_records_by(
          records: User.where(id: u1.id),
          filter: { type: 'group', predicate: 'and', filters: [filter] },
          context: nil
        ).relation
        # Group with single failing child, filter_records_by returns original records
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end
  end
end

RSpec.describe 'round10' + ' - ' + 'Relation scope preservation' do
  describe 'Relation scope preservation' do
    it 'keeps a caller relation filterable with its ordering and limit' do
      first = create(:user, first_name: 'Alice')
      create(:user, first_name: 'Bob')

      result = Scry.filter_records_by(
        records: User.order(:first_name).limit(1),
        filter: { type: 'group', predicate: 'and', filters: [] },
        context: nil
      ).relation

      expect(result.limit_value).to eq(1)
      expect(result.order_values).to be_present
      expect(result.first).to eq(first)
    end
  end
end

RSpec.describe 'round10' + ' - ' + 'Dead TypeScript comments removed from group.rb' do
  describe 'Dead TypeScript comments removed from group.rb' do
    it 'group.rb file ends at the class/module closing' do
      file_path = File.expand_path('../../../lib/scry/filters/group.rb', __dir__)
      content = File.read(file_path)
      lines = content.lines
      expect(content).not_to include('type PropertyFilter')
      expect(content).not_to include('type GroupFilter')
      expect(content).not_to include('type AssociationFilter')
      expect(content).not_to include('type AggregateFilter')
      expect(lines.last).to eq("end\n")
    end
  end
end
