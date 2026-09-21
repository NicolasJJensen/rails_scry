# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'aggregate contracts' do
  describe 'Aggregate error handling' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |cfg|
          cfg.invalid_filter_policy = :raise
          original = User.scry_permissions.deep_dup(klass: User)
          begin
            example.run
          ensure
            User.scry_permissions = original
            User.scry_permissions.clear_caches!
          end
        end
      end
  
      it 'raises for missing reflection' do
        filter = { type: 'aggregate', association: 'nonexistent', aggregate: 'count', predicate: 'gt', args: [1] }
        expect { Scry.filter_records_by(records: User, filter:, context: nil).relation }
          .to raise_error(Scry::FilterError, /invalid or missing association/)
      end
  
      it 'raises for disallowed association' do
        User.add_filter_permission(:associations, list_type: :blacklist) { [:emails] }
        User.scry_permissions.clear_caches!
  
        filter = { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [1] }
        expect { Scry.filter_records_by(records: User, filter:, context: nil).relation }
          .to raise_error(Scry::FilterError, /disallowed aggregate association/)
      end
  
      it 'raises for invalid aggregate function' do
        filter = { type: 'aggregate', association: 'emails', aggregate: 'median', predicate: 'gt', args: [1] }
        expect { Scry.filter_records_by(records: User, filter:, context: nil).relation }
          .to raise_error(Scry::FilterError, /invalid aggregate/)
      end
  
      it 'raises for denied aggregate permission' do
        User.add_filter_permission(:aggregates, list_type: :whitelist) do |_ctx|
          { emails: { count: true } }
        end
        User.scry_permissions.clear_caches!
  
        filter = { type: 'aggregate', association: 'emails', property: 'id', aggregate: 'sum', predicate: 'gt', args: [0] }
        expect { Scry.filter_records_by(records: User, filter:, context: nil).relation }
          .to raise_error(Scry::FilterError, /disallowed aggregate/)
      end
  
      it 'raises for unknown predicate in HAVING clause' do
        filter = { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'nonexistent', args: [1] }
        expect { Scry.filter_records_by(records: User, filter:, context: nil).relation }
          .to raise_error(Scry::FilterError, /disallowed aggregate predicate/)
      end
    end

  describe 'Aggregate SUM DISTINCT with textual predicate' do
      it 'routes through standard HAVING path without error' do
        tech = Technician.create!(name: 'T', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
        job = Job.create!(title: 'J', duration_hours: 1, priority: 3, crew_size: 1)
        sa = ScheduleAssignment.new(job: job, technician: tech, scheduled_start: Time.current, scheduled_end: Time.current + 1.hour, travel_time_minutes: 10, travel_distance_km: 5)
        sa.save(validate: false)
  
        filter = {
          type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes',
          aggregate: 'sum', predicate: 'gteq', args: [5], distinct?: true
        }
        instance = Scry::Filters::Aggregate.new(model: Technician, filter: filter, context: nil)
        result = instance.apply
        expect(result.relation).to include(tech)
      end
    end

  describe 'Aggregate with unrecognized aggregate' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |cfg|
          cfg.invalid_filter_policy = :raise
          example.run
        end
      end
  
      it 'raises for an unrecognized aggregate function' do
        expect {
          Scry.filter_records_by(
            records: User,
            filter: {
              type: 'group', predicate: 'and', filters: [
                { type: 'aggregate', association: 'emails', aggregate: 'percentile', predicate: 'gt', args: [1] }
              ]
            },
            context: nil
          ).relation
        }.to raise_error(Scry::FilterError, /invalid aggregate or missing builder/)
      end
    end
end
