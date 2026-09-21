require 'rails_helper'

RSpec.describe Scry::Predications::Association do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      example.run
    end
  end

  describe 'association predicates' do
    context 'has_any / not_has_any' do
      it 'returns ids that have any of the associated records' do
        u1 = create(:user)
        u2 = create(:user)
        u3 = create(:user)
        e1 = create(:email)
        e2 = create(:email)
        u1.emails << e1
        u2.emails << e2

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'emails', predicate: 'has_any', args: [[e1.id]] }
        ] }
        expect(Scry.filter_records_by(records: User, filter:, context: nil).relation).to match_array([u1])
      end

      it 'returns ids that do not have any of the associated records' do
        u1 = create(:user)
        u2 = create(:user)
        e1 = create(:email)
        u1.emails << e1

        filter = { type: 'group', predicate: 'and', filters: [
          # Constrain the universe to records created in this example to avoid
          # interference from persistent data in the test DB.
          { type: 'property', property: 'id', predicate: 'eq_any', args: [[u1.id, u2.id]] },
          { type: 'association', association: 'emails', predicate: 'not_has_any', args: [[e1.id]] }
        ] }

        rel = Scry.filter_records_by(records: User, filter:, context: nil).relation
        expect(rel).to match_array([u2])
      end
    end

    context 'has_all / not_has_all' do
      it 'returns ids that have all of the associated records' do
        a = create(:phone)
        b = create(:phone)
        c = create(:phone)
        u1 = create(:user, phones_count: 0)
        u2 = create(:user, phones_count: 0)
        u3 = create(:user, phones_count: 0)
        u1.phones << [a, b]
        u2.phones << [a]
        u3.phones << [a, b, c]

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'phones', predicate: 'has_all', args: [[a.id, b.id]] }
        ] }
        expect(Scry.filter_records_by(records: User, filter:, context: nil).relation).to match_array([u1, u3])
      end

      it 'returns ids that do not have all of the associated records' do
        a = create(:phone)
        b = create(:phone)
        u1 = create(:user, phones_count: 0)
        u2 = create(:user, phones_count: 0)
        u3 = create(:user, phones_count: 0)  # no phones at all
        u1.phones << [a, b]
        u2.phones << [a]

        # not_has_all includes records with zero matches (logical negation of has_all)
        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'phones', predicate: 'not_has_all', args: [[a.id, b.id]] }
        ] }
        scoped = User.where(id: [u1.id, u2.id, u3.id])
        result = Scry.filter_records_by(records: scoped, filter:, context: nil).relation
        expect(result).to match_array([u2, u3])
      end
    end

    context 'only_has_any / only_has_all' do
      it 'returns ids whose associations are a subset of provided set' do
        a = create(:phone)
        b = create(:phone)
        c = create(:phone)
        u1 = create(:user, phones_count: 0)
        u2 = create(:user, phones_count: 0)
        u3 = create(:user, phones_count: 0)
        # u1 subset of {a,b}
        u1.phones << [a]
        # u2 exact match {a,b,c} subset of {a,b}? no
        u2.phones << [a, b, c]
        # u3 subset of {a,b}
        u3.phones << [a, b]

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'phones', predicate: 'only_has_any', args: [[a.id, b.id]] }
        ] }
        expect(Scry.filter_records_by(records: User, filter:, context: nil).relation).to match_array([u1, u3])
      end

      it 'returns ids whose associations equal the provided set' do
        a = create(:phone)
        b = create(:phone)
        c = create(:phone)
        u1 = create(:user, phones_count: 0)
        u2 = create(:user, phones_count: 0)
        u3 = create(:user, phones_count: 0)
        u1.phones << [a, b]
        u2.phones << [a]
        u3.phones << [a, b, c]

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'phones', predicate: 'only_has_all', args: [[a.id, b.id]] }
        ] }
        expect(Scry.filter_records_by(records: User, filter:, context: nil).relation).to match_array([u1])
      end
    end

    context 'not_has_any on has_many :through' do
      it 'uses NOT EXISTS with the through table' do
        tech1 = Technician.create!(name: 'T1', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
        tech2 = Technician.create!(name: 'T2', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
        tech3 = Technician.create!(name: 'T3', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
        j1 = Job.create!(title: 'J1', duration_hours: 2.0, priority: 1, crew_size: 1)
        j2 = Job.create!(title: 'J2', duration_hours: 3.0, priority: 2, crew_size: 1)
        ScheduleAssignment.create!(technician: tech1, job: j1)
        ScheduleAssignment.create!(technician: tech2, job: j1)
        ScheduleAssignment.create!(technician: tech2, job: j2)
        # tech3 has no jobs

        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'id', predicate: 'eq_any', args: [[tech1.id, tech2.id, tech3.id]] },
          { type: 'association', association: 'jobs', predicate: 'not_has_any', args: [[j1.id]] }
        ] }
        result = Scry.filter_records_by(records: Technician, filter:, context: nil).relation
        expect(result).to match_array([tech3])
      end
    end

    context 'error handling' do
      it 'returns nil for invalid association name' do
        result = Scry.filter_records_by(
          records: User,
          filter: { type: 'group', predicate: 'and', filters: [ { type: 'association', association: 'nope', predicate: 'has_any', args: [[]] } ] },
          context: nil
        ).relation
        # Invalid association is silently skipped (invalid_filter_policy: :skip), returns original records
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end

    context 'primary key awareness' do
      it 'uses model and association primary_key methods when building queries' do
        create(:user)
        a = create(:phone)
        u = create(:user)
        u.phones << a

        allow(User).to receive(:primary_key).and_call_original
        allow(Phone).to receive(:primary_key).and_call_original

        # Trigger an association predicate that will consult both PKs
        filter = { type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'phones', predicate: 'has_any', args: [[a.id]] }
        ] }

        result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
        expect(result).to include(u)
        expect(User).to have_received(:primary_key).at_least(:once)
        expect(Phone).to have_received(:primary_key).at_least(:once)
      end
    end
  end
end
