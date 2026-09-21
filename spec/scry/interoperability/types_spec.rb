require_relative 'support'

RSpec.describe 'Native type and aggregate contracts', interoperability: true do
  it 'AF-10 discovers array capabilities without scalar text operators' do
    predicates = Technician.filter_predicate_permissions[:skills]
    expect(predicates).to include(:array_contains, :array_overlaps)
    expect(predicates).not_to include(:matches)
  end

  it 'AF-10 discovers JSONB capabilities' do
    expect(Technician.filter_predicate_permissions[:work_hours]).to include(:contains)
  end

  it 'AF-11 executes array containment using the column type' do
    tech = Technician.create!(name: 'Array contract', skills: ['ruby', 'sql'])
    expect(apply(Technician.where(id: tech.id), property('skills', 'array_contains', ['ruby'])).ids).to eq([tech.id])
    expect(apply(Technician.where(id: tech.id), property('skills', 'array_contains', ['java']))).to be_empty
  end

  it 'AF-11 executes JSONB containment using the column type' do
    tech = Technician.create!(name: 'JSON contract', work_hours: {mon: 8})
    expect(apply(Technician.where(id: tech.id), property('work_hours', 'contains', {mon: 8})).ids).to eq([tech.id])
    expect(apply(Technician.where(id: tech.id), property('work_hours', 'contains', {mon: 4}))).to be_empty
  end

  it 'AF-12 honors DISTINCT for AVG' do
    tech = Technician.create!(name: 'Average contract')
    job = Job.create!(title: 'Average contract')
    [1, 1, 4].each { |n| ScheduleAssignment.create!(technician: tech, job: job, travel_time_minutes: n) }
    filter = aggregate('schedule_assignments', 'gteq', 2.4, aggregate: 'avg', property: 'travel_time_minutes', distinct?: true)
    expect(apply(Technician.where(id: tech.id), filter).ids).to eq([tech.id])
  end

  it 'AF-12 preserves the result type of a zero-inclusive temporal MIN' do
    tech = Technician.create!(name: 'Temporal contract')
    job = Job.create!(title: 'Temporal contract')
    ScheduleAssignment.create!(technician: tech, job: job, scheduled_start: Time.utc(2026, 1, 1))
    filter = aggregate('schedule_assignments', 'gteq', '2025-01-01', aggregate: 'min', property: 'scheduled_start')
    expect(apply(Technician.where(id: tech.id), filter).ids).to eq([tech.id])
  end
end
