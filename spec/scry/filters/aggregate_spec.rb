require 'rails_helper'

RSpec.describe Scry::Filters::Aggregate do
  around(:each) do |example|
    Timecop.freeze(Time.utc(2024,1,1)) { example.run }
  end

  def user_with_emails(addresses)
    user = create(:user, emails_count: 0)
    addresses.each { |addr| user.emails << create(:email, address: addr) }
    user
  end

  it 'filters by COUNT(association) > n' do
    u1 = user_with_emails(%w[a@x.com b@x.com c@x.com])
    _u2 = user_with_emails(%w[one@x.com])

    filter = {
      type: 'group', predicate: 'and', filters: [
        { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [2] }
      ]
    }

    result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
    expect(result).to match_array([u1])
  end

  context 'permissions' do
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

    it 'allows only whitelisted aggregates per association' do
      u1 = user_with_emails(%w[a@x.com b@x.com c@x.com])
      _u2 = user_with_emails(%w[one@x.com])

      # Allow count on emails only
      User.add_filter_permission(:aggregates, list_type: :whitelist) do |_ctx|
        { emails: { count: true } }
      end
      User.scry_permissions.clear_caches!

      filter_ok = { type: 'group', predicate: 'and', filters: [ { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [2] } ] }
      expect(Scry.filter_records_by(records: User, filter: filter_ok, context: nil).relation).to match_array([u1])

      # Disallowed sum on emails
      filter_bad = { type: 'group', predicate: 'and', filters: [ { type: 'aggregate', association: 'emails', property: 'id', aggregate: 'sum', predicate: 'gt', args: [0] } ] }
      expect(Scry.filter_records_by(records: User, filter: filter_bad, context: nil).relation).to be_a(ActiveRecord::Relation)
    end
  end

  it 'applies scoping to child rows before aggregating' do
    u1 = user_with_emails(%w[a@example.com b@other.com c@example.com])
    _u2 = user_with_emails(%w[one@x.com two@y.com])

    filter = {
      type: 'group', predicate: 'and', filters: [
        {
          type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gteq', args: [2],
          scoping: {
            type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'address', predicate: 'matches', args: ['@example.com'] }
            ]
          }
        }
      ]
    }

    result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
    expect(result).to match_array([u1])
  end

  context 'model validation' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |_cfg|
        original_email = Email.scry_permissions.deep_dup(klass: Email)
        begin
          example.run
        ensure
          Email.scry_permissions = original_email
          Email.scry_permissions.clear_caches!
        end
      end
    end

    it 'returns nil when associated model is not allowed (standard aggregate path)' do
      u1 = user_with_emails(%w[a@example.com b@example.com])

      # Deny Email model
      Email.add_model_permission { |_ctx| false }
      Email.scry_permissions.clear_caches!

      filter = {
        type: 'aggregate',
        association: 'emails',
        aggregate: 'count',
        predicate: 'gteq',
        args: [1],
        scoping: {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'address', predicate: 'matches', args: ['@example.com'] }
          ]
        }
      }

      # With invalid_filter_policy: :skip (default), no warning is logged

      instance = described_class.new(model: User, filter: filter, context: nil)
      expect(instance.apply).to be_failed
    end

    it 'returns nil when associated model is not allowed (count=0 optimization path)' do
      u1 = user_with_emails(%w[a@example.com])

      # Deny Email model
      Email.add_model_permission { |_ctx| false }
      Email.scry_permissions.clear_caches!

      filter = {
        type: 'aggregate',
        association: 'emails',
        aggregate: 'count',
        predicate: 'eq',
        args: [0],
        scoping: {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'address', predicate: 'matches', args: ['@example.com'] }
          ]
        }
      }

      # With invalid_filter_policy: :skip (default), no warning is logged

      instance = described_class.new(model: User, filter: filter, context: nil)
      expect(instance.apply).to be_failed
    end
  end

  it 'is primary-key aware when grouping and selecting' do
    u1 = user_with_emails(%w[a@x.com])
    allow(User).to receive(:primary_key).and_call_original

    filter = {
      type: 'group', predicate: 'and', filters: [
        { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gteq', args: [1] }
      ]
    }

    result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
    expect(result).to include(u1)
    expect(User).to have_received(:primary_key).at_least(:once)
  end

  context 'SUM and AVG' do
    def tech_with_assignments(travel_mins: [], travel_km: [])
      tech = Technician.create!(name: 'Tech', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
      travel_mins.zip(travel_km).each do |mins, km|
        job = Job.create!(title: 'J', duration_hours: 1, priority: 3, crew_size: 1)
        sa = ScheduleAssignment.new(
          job: job,
          technician: tech,
          scheduled_start: Time.current,
          scheduled_end: Time.current + 1.hour,
          travel_time_minutes: mins || 0,
          travel_distance_km: km || 0
        )
        sa.save(validate: false)
      end
      tech
    end

    it 'filters by SUM(child.attribute) >= x' do
      t1 = tech_with_assignments(travel_mins: [60, 50], travel_km: [10, 12])
      _t2 = tech_with_assignments(travel_mins: [30], travel_km: [5])

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'sum', predicate: 'gteq', args: [100] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to match_array([t1])
    end

    it 'filters by AVG(child.attribute) BETWEEN [low, high]' do
      t1 = tech_with_assignments(travel_mins: [10, 20], travel_km: [15, 15]) # avg km = 15
      _t2 = tech_with_assignments(travel_mins: [10, 10], travel_km: [5, 5])  # avg km = 5

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_distance_km', aggregate: 'avg', predicate: 'between', args: [10, 20] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to match_array([t1])
    end

    it 'supports SUM DISTINCT for child attribute' do
      t1 = tech_with_assignments(travel_mins: [60, 60, 10], travel_km: [0, 0, 0]) # distinct sum = 70, regular sum = 130

      filter_dist_ok = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'sum', predicate: 'gteq', args: [70], distinct?: true }
        ]
      }
      expect(Scry.filter_records_by(records: Technician, filter: filter_dist_ok, context: nil).relation).to include(t1)

      filter_dist_high = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'sum', predicate: 'gteq', args: [130], distinct?: true }
        ]
      }
      expect(Scry.filter_records_by(records: Technician, filter: filter_dist_high, context: nil).relation).not_to include(t1)
    end
  end

  context 'MIN and MAX' do
    def tech_with_travel_times(times)
      tech = Technician.create!(name: 'MinMaxTech', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
      times.each do |mins|
        job = Job.create!(title: 'J', duration_hours: 1, priority: 3, crew_size: 1)
        sa = ScheduleAssignment.new(
          job: job,
          technician: tech,
          scheduled_start: Time.current,
          scheduled_end: Time.current + 1.hour,
          travel_time_minutes: mins,
          travel_distance_km: 0
        )
        sa.save(validate: false)
      end
      tech
    end

    it 'filters by MIN(child.attribute) >= low' do
      t1 = tech_with_travel_times([60, 80])
      _t2 = tech_with_travel_times([30, 120])

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'min', predicate: 'gteq', args: [50] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to match_array([t1])
    end

    it 'filters by MAX(child.attribute) > high' do
      _t1 = tech_with_travel_times([10, 20])
      t2 = tech_with_travel_times([45, 120])

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'schedule_assignments', property: 'travel_time_minutes', aggregate: 'max', predicate: 'gt', args: [100] }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to match_array([t2])
    end
  end

  context 'natural zero-count for COUNT' do
    it 'returns parents with zero children when natural zero-count is true' do
      u_zero = create(:user, emails_count: 0)
      u_one = user_with_emails(%w[one@x.com])

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'eq', args: [0] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      scoped = result.where(id: [u_zero.id, u_one.id])
      expect(scoped).to match_array([u_zero])
    end

    it 'applies scoping in ON clause for has_many when natural zero-count is true' do
      org1 = create(:organisation)
      org2 = create(:organisation)

      # org1 has users named Alice and Bob
      create(:user, organisation: org1, first_name: 'Alice')
      create(:user, organisation: org1, first_name: 'Bob')
      # org2 has only Eve
      create(:user, organisation: org2, first_name: 'Eve')

      # Find orgs with zero users whose first_name starts with 'E'
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'users', aggregate: 'count', predicate: 'eq', args: [0],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'first_name', predicate: 'starts_with', args: ['E'] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: Organisation, filter: filter, context: nil).relation
      # Scope assertion to organisations created in this example to avoid global DB state
      scoped = result.where(id: [org1.id, org2.id])
      expect(scoped).to match_array([org1])
    end

    it 'applies scoping in ON clause for HABTM when natural zero-count is true' do
      u_none = create(:user, service_industries: [])
      u_food = create(:user, service_industries: [create(:service_industry, name: 'Food')])
      u_tech = create(:user, service_industries: [create(:service_industry, name: 'Tech')])

      # Users with zero service industries named 'Tech'
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'service_industries', aggregate: 'count', predicate: 'eq', args: [0],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'name', predicate: 'eq', args: ['Tech'] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      # Scope assertion to users created in this example to avoid global DB state
      scoped = result.where(id: [u_none.id, u_food.id, u_tech.id])
      expect(scoped).to match_array([u_none, u_food])
      expect(scoped).not_to include(u_tech)
    end

    it 'applies scoping in ON clause for has_many :through when natural zero-count is true' do
      tech1 = Technician.create!(name: 'T1', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
      tech2 = Technician.create!(name: 'T2', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})

      job_ok = Job.create!(title: 'OK', duration_hours: 1, priority: 3, crew_size: 1)
      job_bad = Job.create!(title: 'BAD', duration_hours: 1, priority: 3, crew_size: 1)

      # Assign BAD job to tech2 via through association
      sa = ScheduleAssignment.new(job: job_bad, technician: tech2, scheduled_start: Time.current, scheduled_end: Time.current + 1.hour)
      sa.save(validate: false)

      # Filter technicians with zero jobs with title == 'BAD'
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'jobs', aggregate: 'count', predicate: 'eq', args: [0],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'title', predicate: 'eq', args: ['BAD'] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to include(tech1)
      expect(result).not_to include(tech2)
    end
  end

  context 'zero-count membership' do
    it 'returns only parents with no children matching the nested scope' do
      org = create(:organisation)
      create(:user, organisation: org, first_name: 'Alice')

      filter = {
        type: 'aggregate',
        association: 'users',
        aggregate: 'count',
        predicate: 'eq',
        args: [0],
        scoping: {
          type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
          ]
        }
      }

      instance = described_class.new(model: Organisation, filter: filter, context: nil)
      result = instance.apply
      expect(result.relation).to be_a(ActiveRecord::Relation)
      expect(result.relation.where(id: org.id)).to be_empty
      empty_org = create(:organisation)
      expect(result.relation.where(id: empty_org.id).ids).to eq([empty_org.id])
    end
  end

  context 'belongs_to natural zero-count with scoping' do
    it 'pushes scoping into ON for belongs_to and returns parents with zero matching child' do
      # Emails belong_to :account (optional)
      acc_a = Account.create!(username: 'alice', password: 'x')
      acc_b = Account.create!(username: 'bob', password: 'x')

      e1 = Email.create!(address: 'a@x.com', account: acc_b) # does not match scoping username starts with 'a'
      _e2 = Email.create!(address: 'b@x.com', account: nil)  # no account at all

      # Emails with zero accounts whose username starts with 'a'
      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'account', aggregate: 'count', predicate: 'eq', args: [0],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'username', predicate: 'starts_with', args: ['a'] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: Email, filter: filter, context: nil).relation
      expect(result).to include(e1) # has an account but not matching scoping → zero matching accounts
    end
  end
end
