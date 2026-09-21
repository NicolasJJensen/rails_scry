# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round13' + ' - ' + 'Shared predicate pipeline' do
  describe 'Shared predicate pipeline' do
    let(:user) { create(:user, first_name: 'Alice') }

    describe 'apply_predicate_validator' do
      it 'propagates validator callback exceptions under raise policy' do
        Scry.configuration.with_temporary_settings do |config|
          config.callback_error_policy = :raise

          instance = Scry::Filters::Property.new(
            model: User, filter: { property: 'first_name', predicate: 'eq', value: 'x' }, context: nil
          )
          bad_predicate_obj = { validator: ->(_v) { raise ArgumentError, 'bad value' } }

          expect {
            instance.__send__(:apply_predicate_validator, bad_predicate_obj, 'x')
          }.to raise_error(ArgumentError, 'bad value')
        end
      end
    end

    describe 'apply_predicate_formatter' do
      it 'propagates formatter callback exceptions under raise policy' do
        Scry.configuration.with_temporary_settings do |config|
          config.callback_error_policy = :raise

          instance = Scry::Filters::Property.new(
            model: User, filter: { property: 'first_name', predicate: 'eq', value: 'x' }, context: nil
          )
          bad_predicate_obj = { formatter: ->(_v) { raise RuntimeError, 'format boom' } }

          expect {
            instance.__send__(:apply_predicate_formatter, bad_predicate_obj, 'x')
          }.to raise_error(RuntimeError, 'format boom')
        end
      end
    end

    describe 'build_predicate_node' do
      it 'validates custom_predicate return type' do
        Scry.configuration.with_temporary_settings do |config|
          config.callback_error_policy = :raise
          config.invalid_filter_policy = :raise

          config.register_predicate(:bad_node, types: [:textual], compounds: false) { |_attr, _val| 'not an arel node' }

          filter = {
            type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'first_name', predicate: 'bad_node', args: ['x'] }
            ]
          }

          expect {
            Scry.filter_records_by(records: User, filter: filter, context: nil).relation
          }.to raise_error(Scry::FilterError, /returned invalid node/)
        end
      end
    end

    describe 'valid_arel_node?' do
      it 'returns true only for Arel::Nodes::Node subclasses' do
        base = Scry::Filters::Property.new(
          model: User, filter: { property: 'first_name', predicate: 'eq', value: 'x' }, context: nil
        )
        node = Arel::Nodes::Equality.new(User.arel_table[:first_name], Arel::Nodes.build_quoted('x'))
        literal = Arel.sql('1')

        expect(base.__send__(:valid_arel_node?, node)).to be true
        expect(base.__send__(:valid_arel_node?, literal)).to be false
        expect(base.__send__(:valid_arel_node?, 'string')).to be false
        expect(base.__send__(:valid_arel_node?, nil)).to be false
      end
    end
  end

  # ── 2. NOT_BETWEEN in aggregate HAVING (T13-8) ──────────────────────────────
end

RSpec.describe 'round13' + ' - ' + 'NOT_BETWEEN in aggregate HAVING' do
  describe 'NOT_BETWEEN in aggregate HAVING' do
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

    def tech_with_assignments(count:)
      tech = Technician.create!(name: "Tech#{rand(1000)}", max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
      count.times do
        job = Job.create!(title: 'J', duration_hours: 1, priority: 3, crew_size: 1)
        sa = ScheduleAssignment.new(
          job: job, technician: tech,
          scheduled_start: Time.current, scheduled_end: Time.current + 1.hour,
          travel_time_minutes: 0, travel_distance_km: 0
        )
        sa.save(validate: false)
      end
      tech
    end

    it 'filters by NOT_BETWEEN on aggregate count' do
      Technician.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
        { schedule_assignments: { count: true } }
      end
      Technician.scry_permissions.clear_caches!

      t1 = tech_with_assignments(count: 1) # inside range [1,3]
      t2 = tech_with_assignments(count: 5) # outside range
      t3 = tech_with_assignments(count: 2) # inside range

      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'schedule_assignments',
            aggregate: 'count', predicate: 'not_between', args: [1, 3]
          }
        ]
      }

      result = Scry.filter_records_by(
        records: Technician.where(id: [t1.id, t2.id, t3.id]),
        filter: filter, context: nil
      ).relation

      expect(result).to match_array([t2])
    end
  end

  # ── 3. has_many :through LEFT JOIN with scoping (T13-9) ─────────────────────
end

RSpec.describe 'round13' + ' - ' + 'has_many :through LEFT JOIN with scoping' do
  describe 'has_many :through LEFT JOIN with scoping' do
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

    it 'filters with include_zero on has_many :through with scoping' do
      Technician.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
        { jobs: { count: true } }
      end
      Technician.scry_permissions.clear_caches!

      t1 = Technician.create!(name: 'HasJobs', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
      t2 = Technician.create!(name: 'NoJobs', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})

      high_priority_job = Job.create!(title: 'Urgent', duration_hours: 2, priority: 1, crew_size: 1)
      low_priority_job = Job.create!(title: 'Routine', duration_hours: 1, priority: 5, crew_size: 1)

      # t1 has both jobs, t2 has only the low-priority job
      [high_priority_job, low_priority_job].each do |job|
        sa = ScheduleAssignment.new(
          technician: t1, job: job,
          scheduled_start: Time.current, scheduled_end: Time.current + 1.hour,
          travel_time_minutes: 0, travel_distance_km: 0
        )
        sa.save(validate: false)
      end
      sa = ScheduleAssignment.new(
        technician: t2, job: low_priority_job,
        scheduled_start: Time.current, scheduled_end: Time.current + 1.hour,
        travel_time_minutes: 0, travel_distance_km: 0
      )
      sa.save(validate: false)

      # Count jobs with priority = 1 (high priority), include_zero to use LEFT JOIN through path
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'jobs', aggregate: 'count',
            predicate: 'gteq', args: [1],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'priority', predicate: 'eq', args: [1] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(
        records: Technician.where(id: [t1.id, t2.id]),
        filter: filter, context: nil
      ).relation

      # Only t1 has a high-priority job
      expect(result).to match_array([t1])
    end
  end

  # ── 4. Attribute transform exception recovery (T13-2) ──────────────────────
end

RSpec.describe 'round13' + ' - ' + 'Attribute transform exception recovery' do
  describe 'Attribute transform exception recovery' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |_cfg|
        original = User.scry_permissions.deep_dup(klass: User)
        begin
          example.run
        ensure
          User.scry_permissions = original
          User.scry_permissions.clear_caches!
        end
      end
    end

    it 'propagates attribute transform callback exceptions under raise policy' do

      user = create(:user, first_name: 'Alice')

      User.add_filter_transform(:first_name, on: :attribute) do |_attr, _ctx|
        raise RuntimeError, 'transform exploded'
      end
      User.scry_permissions.clear_caches!

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        ]
      }

      expect { Scry.filter_records_by(
        records: User.where(id: user.id), filter: filter, context: nil
      ).relation }.to raise_error(RuntimeError, 'transform exploded')
    end
  end

  # ── 5. Association NameError recovery (T13-6) ──────────────────────────────
end

RSpec.describe 'round13' + ' - ' + 'Association NameError recovery' do
  describe 'Association NameError recovery' do
    it 'handles NameError when association model class cannot be resolved' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn

        user = create(:user)
        User.scry_permissions.clear_caches!

        # Create a bad reflection that raises NameError on .klass.
        # Return it from reflect_on_association (used by Association filter init)
        # but leave reflect_on_all_associations untouched (used by allowed_associations).
        real_reflection = User.reflect_on_association(:organisation)
        bad_reflection = double('bad_reflection',
          name: real_reflection.name,
          macro: real_reflection.macro,
          foreign_key: real_reflection.foreign_key
        )
        allow(bad_reflection).to receive(:klass).and_raise(NameError, 'uninitialized constant BadModel')
        allow(User).to receive(:reflect_on_association).and_call_original
        allow(User).to receive(:reflect_on_association).with('organisation').and_return(bad_reflection)

        expect(Rails.logger).to receive(:warn).with(/association model not found/)

        filter = {
          type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'organisation', predicate: 'has_any', args: [[1]] }
          ]
        }

        result = Scry.filter_records_by(
          records: User.where(id: user.id), filter: filter, context: nil
        ).relation

        expect(result).to be_a(ActiveRecord::Relation)
      end
    end
  end
end
