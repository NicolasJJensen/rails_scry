# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round12' + ' - ' + 'Aggregate filtering through the public API' do
  describe 'Aggregate filtering through the public API' do
    it 'keeps repeated aggregate queries stable without exposing aliases' do
      user = create(:user, emails_count: 0)
      user.emails << create(:email, address: 'aggregate@example.com')

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'eq', args: [1] }
        ]
      }

      first_result = Scry.filter_records_by(records: User.where(id: user.id), filter: filter, context: nil).relation
      second_result = Scry.filter_records_by(records: User.where(id: user.id), filter: filter, context: nil).relation

      expect(first_result.ids).to eq([user.id])
      expect(second_result.ids).to eq([user.id])
    end
  end
end

RSpec.describe 'round12' + ' - ' + 'Group OR NoMethodError re-raise' do
  describe 'Group OR NoMethodError re-raise' do
    it 're-raises NoMethodError from query combination (programming bug, not user error)' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn

        create(:user, first_name: 'Alice')
        create(:user, first_name: 'Bob')

        filter = {
          type: 'group', predicate: 'or', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] },
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Bob'] }
          ]
        }

        # Stub .or on Arel AST nodes to raise NoMethodError, simulating a programming bug.
        allow_any_instance_of(Arel::Nodes::Node).to receive(:or).and_raise(NoMethodError, 'simulated OR failure')

        expect {
          Scry.filter_records_by(
            records: User.all,
            filter: filter,
            context: nil
          ).relation
        }.to raise_error(NoMethodError, /simulated OR failure/)
      end
    end
  end
end

RSpec.describe 'round12' + ' - ' + 'Aggregate scoping through the public API' do
  describe 'Aggregate scoping through the public API' do
    it 'applies a child relation scope to the aggregate' do
      user = create(:user, emails_count: 0)
      user.emails << create(:email, address: 'included@example.com')
      user.emails << create(:email, address: 'excluded@example.com')

      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'eq', args: [1],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'address', predicate: 'eq', args: ['included@example.com'] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: User.where(id: user.id), filter: filter, context: nil).relation

      expect(result.ids).to eq([user.id])
    end
  end
end

RSpec.describe 'round12' + ' - ' + 'Set-based predicate_metadata' do
  describe 'Set-based predicate_metadata' do
    it 'returns correct predicate metadata' do
      metadata = User.scry_permissions.predicate_metadata(nil)
      expect(metadata).to be_a(Hash)
      expect(metadata.keys).to include(:eq)
      expect(metadata.keys).to include(:matches)
    end
  end

  # ── 2. Distinct SUM aggregate (T12-6) ───────────────────────────────────────
end

RSpec.describe 'round12' + ' - ' + 'Distinct SUM aggregate' do
  describe 'Distinct SUM aggregate' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |_cfg|
        original = Technician.scry_permissions.deep_dup(klass: Technician)
        begin
          example.run
        ensure
          Technician.scry_permissions = original
          Technician.scry_permissions.clear_caches!
        end
      end
    end

    def tech_with_assignments(travel_mins:)
      tech = Technician.create!(name: 'Tech', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
      travel_mins.each do |mins|
        job = Job.create!(title: 'J', duration_hours: 1, priority: 3, crew_size: 1)
        sa = ScheduleAssignment.new(
          job: job, technician: tech,
          scheduled_start: Time.current, scheduled_end: Time.current + 1.hour,
          travel_time_minutes: mins, travel_distance_km: 0
        )
        sa.save(validate: false)
      end
      tech
    end

    it 'filters by SUM DISTINCT on a numeric property' do
      Technician.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
        { schedule_assignments: { sum: [:travel_time_minutes] } }
      end
      Technician.scry_permissions.clear_caches!

      # t1: travel times [30, 30, 60] => distinct sum = 90 (30 + 60)
      t1 = tech_with_assignments(travel_mins: [30, 30, 60])
      # t2: travel times [10, 20] => distinct sum = 30
      t2 = tech_with_assignments(travel_mins: [10, 20])

      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'schedule_assignments',
            property: 'travel_time_minutes', aggregate: 'sum',
            predicate: 'gteq', args: [50], distinct?: true
          }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to include(t1)
      expect(result).not_to include(t2)
    end
  end

  # ── 3. HABTM NOT EXISTS optimization (T12-8) ───────────────────────────────
end

RSpec.describe 'round12' + ' - ' + 'HABTM NOT EXISTS with scoping' do
  describe 'HABTM NOT EXISTS with scoping' do
    it 'returns users with no matching HABTM emails (count == 0 + scoping)' do
      org = create(:organisation)
      u1 = create(:user, organisation: org)
      u2 = create(:user, organisation: org)

      e1 = create(:email, address: 'match@example.com')
      e2 = create(:email, address: 'other@domain.com')

      # u1 has one email matching the scoping, u2 has none
      u1.emails << e1
      u2.emails << e2

      # Count emails with id == e1.id equal to 0, natural zero-count true
      # This should trigger the HABTM NOT EXISTS optimization
      filter = {
        type: 'aggregate', association: 'emails', aggregate: 'count',
        predicate: 'eq', args: [0],
        scoping: {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'id', predicate: 'eq', args: [e1.id] }
          ]
        }
      }

      result = Scry.filter_records_by(
        records: User.where(id: [u1.id, u2.id]),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation

      # u1 has 1 email matching e1.id (count != 0), u2 has 0 matching (count == 0)
      expect(result).to match_array([u2])
    end
  end

  # ── 4. TypeRegistry cycle detection (T12-12) ───────────────────────────────
end

RSpec.describe 'round12' + ' - ' + 'TypeRegistry cycle detection' do
  describe 'TypeRegistry cycle detection' do
    it 'handles circular type group definitions without infinite loop' do
      registry = Scry::TypeRegistry.new

      # Register circular groups: A contains B, B contains A
      registry.register(:cycle_a, :cycle_b)
      registry.register(:cycle_b, :cycle_a)

      # Should not hang or raise; should return types including both
      result = registry.by_group(:cycle_a)
      expect(result).to include(:cycle_a)
      expect(result).to include(:cycle_b)
      expect(result).to include(:all)
    end

    it 'handles deep nesting without infinite loop' do
      registry = Scry::TypeRegistry.new

      registry.register(:deep_a, :deep_b)
      registry.register(:deep_b, :deep_c)
      registry.register(:deep_c, :deep_d)

      result = registry.by_group(:deep_a)
      expect(result).to include(:deep_a)
      expect(result).to include(:deep_b)
      expect(result).to include(:deep_c)
      expect(result).to include(:deep_d)
    end
  end

  # ── 5. belongs_to include_zero aggregate (T12-13) ──────────────────────────
end

RSpec.describe 'round12' + ' - ' + 'belongs_to include_zero aggregate' do
  describe 'belongs_to include_zero aggregate' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |_cfg|
        original = ScheduleAssignment.scry_permissions.deep_dup(klass: ScheduleAssignment)
        original_tech = Technician.scry_permissions.deep_dup(klass: Technician)
        begin
          example.run
        ensure
          ScheduleAssignment.scry_permissions = original
          ScheduleAssignment.scry_permissions.clear_caches!
          Technician.scry_permissions = original_tech
          Technician.scry_permissions.clear_caches!
        end
      end
    end

    it 'filters by aggregate on belongs_to with natural zero-count' do
      # The belongs_to path in apply_left_join_with_optional_scoping (aggregate.rb line 279)
      # ScheduleAssignment belongs_to :job
      Technician.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
        { schedule_assignments: { count: true } }
      end
      Technician.scry_permissions.clear_caches!

      t1 = Technician.create!(name: 'HasAssignments', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
      t2 = Technician.create!(name: 'NoAssignments', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})

      job = Job.create!(title: 'TestJob', duration_hours: 1, priority: 3, crew_size: 1)
      sa = ScheduleAssignment.new(
        technician: t1, job: job,
        scheduled_start: Time.current, scheduled_end: Time.current + 1.hour,
        travel_time_minutes: 0, travel_distance_km: 0
      )
      sa.save(validate: false)

      # Count schedule_assignments >= 1 with natural zero-count (LEFT JOIN path)
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'schedule_assignments',
            aggregate: 'count', predicate: 'gteq', args: [1],
          }
        ]
      }

      result = Scry.filter_records_by(
        records: Technician.where(id: [t1.id, t2.id]),
        filter: filter,
        context: nil
      ).relation

      expect(result).to match_array([t1])
    end
  end
end
