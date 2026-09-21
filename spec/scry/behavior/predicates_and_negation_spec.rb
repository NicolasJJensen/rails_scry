# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round7' + ' - ' + 'Boolean predicates' do
  describe 'Boolean predicates' do
    let!(:active_user) { create(:user, active: true) }
    let!(:inactive_user) { create(:user, active: false) }

    it 'filters by eq_true on boolean column' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'active', predicate: 'eq_true' }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(active_user)
      expect(result).not_to include(inactive_user)
    end

    it 'filters by eq_false on boolean column' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'active', predicate: 'eq_false' }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(inactive_user)
      expect(result).not_to include(active_user)
    end

    it 'filters by eq_true with negate (equivalent to eq_false)' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'active', predicate: 'eq_true', negate: true }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(inactive_user)
      expect(result).not_to include(active_user)
    end
  end

  # ── Negative textual predicates ─────────────────────────────────────────────
end

RSpec.describe 'round7' + ' - ' + 'Negative textual predicates' do
  describe 'Negative textual predicates' do
    let!(:alice) { create(:user, first_name: 'Alice') }
    let!(:bob) { create(:user, first_name: 'Bob') }
    let!(:alfred) { create(:user, first_name: 'Alfred') }

    it 'filters by does_not_start_with' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'does_not_start_with', args: ['Al'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(bob)
      expect(result).not_to include(alice, alfred)
    end

    it 'filters by does_not_end_with' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'does_not_end_with', args: ['ce'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(bob, alfred)
      expect(result).not_to include(alice)
    end

    it 'filters by does_not_match' do
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'does_not_match', args: ['ob'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(alice, alfred)
      expect(result).not_to include(bob)
    end
  end

  # ── Aggregate property permission check ─────────────────────────────────────
end

RSpec.describe 'round7' + ' - ' + 'Aggregate property permission check' do
  describe 'Aggregate property permission check' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |_cfg|
        original_sa = ScheduleAssignment.scry_permissions.deep_dup(klass: ScheduleAssignment)
        begin
          example.run
        ensure
          ScheduleAssignment.scry_permissions = original_sa
          ScheduleAssignment.scry_permissions.clear_caches!
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

    it 'allows SUM on property when property is in allowed_properties' do
      _t1 = tech_with_assignments(travel_mins: [60, 50])

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'sum', predicate: 'gteq', args: [100] }
        ]
      }

      # Default: all properties allowed
      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).not_to be_nil
    end

    it 'blocks SUM on property when property is excluded from allowed_properties' do
      _t1 = tech_with_assignments(travel_mins: [60, 50])

      # Restrict ScheduleAssignment to only allow 'travel_distance_km' (not 'travel_time_minutes')
      ScheduleAssignment.add_filter_permission(:properties, list_type: :whitelist) { |_ctx| [:travel_distance_km] }
      ScheduleAssignment.scry_permissions.clear_caches!

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'sum', predicate: 'gteq', args: [100] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to be_a(ActiveRecord::Relation)
    end

    it 'allows COUNT without property check (count does not use property)' do
      t1 = tech_with_assignments(travel_mins: [60, 50])

      # Restrict ScheduleAssignment to zero properties
      ScheduleAssignment.add_filter_permission(:properties, list_type: :whitelist) { |_ctx| [] }
      ScheduleAssignment.scry_permissions.clear_caches!

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', aggregate: 'count', predicate: 'gteq', args: [2] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to include(t1)
    end
  end

  # ── Strict mode for aggregates ──────────────────────────────────────────────
end

RSpec.describe 'round7' + ' - ' + 'Strict mode for aggregates' do
  describe 'Strict mode for aggregates' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |cfg|
        original_tech = Technician.scry_permissions.deep_dup(klass: Technician)
        begin
          cfg.strict = true
          Technician.scry_permissions.clear_caches!
          example.run
        ensure
          Technician.scry_permissions = original_tech
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

    it 'returns empty aggregates when no aggregate permissions are configured' do
      aggs = Technician.scry_permissions.allowed_aggregates(nil)
      expect(aggs).to be_empty
    end

    it 'blocks aggregate filter when no permissions are whitelisted' do
      _t1 = tech_with_assignments(travel_mins: [60, 50])

      # Need to whitelist associations and properties first, but aggregates should remain empty
      Technician.add_filter_permission(:associations, list_type: :includelist) { |_| [:schedule_assignments] }
      Technician.scry_permissions.clear_caches!

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', aggregate: 'count', predicate: 'gteq', args: [1] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to be_a(ActiveRecord::Relation)
    end

    it 'allows whitelisted aggregates in strict mode' do
      t1 = tech_with_assignments(travel_mins: [60, 50])

      Technician.add_filter_permission(:associations, list_type: :includelist) { |_| [:schedule_assignments] }
      Technician.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
        { schedule_assignments: { count: true } }
      end
      Technician.scry_permissions.clear_caches!

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', aggregate: 'count', predicate: 'gteq', args: [2] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to include(t1)
    end
  end

  # ── Aggregate edge cases ────────────────────────────────────────────────────
end

RSpec.describe 'round7' + ' - ' + 'Aggregate edge cases' do
  describe 'Aggregate edge cases' do
    around(:each) do |example|
      Timecop.freeze(Time.utc(2024, 1, 1)) { example.run }
    end

    def tech_with_assignments(travel_mins: [], travel_km: [])
      tech = Technician.create!(name: 'Tech', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
      travel_mins.zip(travel_km).each do |mins, km|
        job = Job.create!(title: 'J', duration_hours: 1, priority: 3, crew_size: 1)
        sa = ScheduleAssignment.new(
          job: job, technician: tech,
          scheduled_start: Time.current, scheduled_end: Time.current + 1.hour,
          travel_time_minutes: mins || 0, travel_distance_km: km || 0
        )
        sa.save(validate: false)
      end
      tech
    end

    it 'SUM DISTINCT with eq predicate' do
      t1 = tech_with_assignments(travel_mins: [30, 30, 20]) # distinct sum = 50, regular sum = 80

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'sum', predicate: 'eq', args: [50], distinct?: true }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to include(t1)
    end

    it 'SUM DISTINCT with lt predicate' do
      t1 = tech_with_assignments(travel_mins: [10, 10, 5]) # distinct sum = 15
      _t2 = tech_with_assignments(travel_mins: [50, 50, 30]) # distinct sum = 80

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'sum', predicate: 'lt', args: [20], distinct?: true }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to match_array([t1])
    end

    it 'natural zero-count with has_many_through and scoping' do
      t1 = Technician.create!(name: 'NoJobs', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})

      t2 = Technician.create!(name: 'HasJobs', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
      job = Job.create!(title: 'Important', duration_hours: 2, priority: 5, crew_size: 1)
      sa = ScheduleAssignment.new(
        job: job, technician: t2,
        scheduled_start: Time.current, scheduled_end: Time.current + 2.hours,
        travel_time_minutes: 10, travel_distance_km: 5
      )
      sa.save(validate: false)

      # COUNT with natural zero-count for schedule_assignments (has_many) with scoping
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'schedule_assignments', aggregate: 'count',
            predicate: 'gteq', args: [0],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'travel_time_minutes', predicate: 'gteq', args: [5] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to include(t1, t2)
    end

    it 'MIN aggregate with eq predicate' do
      t1 = tech_with_assignments(travel_mins: [10, 20, 30]) # min = 10
      _t2 = tech_with_assignments(travel_mins: [50, 60])    # min = 50

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'min', predicate: 'eq', args: [10] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to match_array([t1])
    end

    it 'MAX aggregate with lteq predicate' do
      t1 = tech_with_assignments(travel_mins: [10, 20])  # max = 20
      _t2 = tech_with_assignments(travel_mins: [50, 100]) # max = 100

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'max', predicate: 'lteq', args: [25] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to match_array([t1])
    end
  end
end
