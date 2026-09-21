require_relative 'support'
require 'bundler'
require 'open3'
require 'rbconfig'

RSpec.describe 'Aggregate operand contracts', interoperability: true do
  SQLITE_CONTRACT = <<~'RUBY'
    gem 'activerecord', "~> #{ENV.fetch('RAILS_VERSION', '8.1')}.0"
    require 'active_record'
    require 'rails_scry'

    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    ActiveRecord::Schema.define do
      create_table(:operand_parents)
      create_table :operand_children do |table|
        table.references :operand_parent, null: false
        table.integer :quantity, null: false
        table.decimal :amount, precision: 10, scale: 2, null: false
        table.datetime :occurred_at, null: false
      end
    end

    class OperandParent < ActiveRecord::Base
      include Scry::Filterable
      has_many :operand_children
    end

    class OperandChild < ActiveRecord::Base
      include Scry::Filterable
      belongs_to :operand_parent
    end

    def aggregate(name, predicate, value, **options)
      {type: 'aggregate', association: 'operand_children', aggregate: name,
       predicate: predicate, value: value, **options}
    end

    def matches(scope, filter)
      group = {type: 'group', predicate: 'and', filters: [filter]}
      Scry.filter_records_by(records: scope, filter: group, context: nil).relation.ids
    end

    matching = OperandParent.create!
    empty = OperandParent.create!
    time = Time.utc(2026, 9, 7, 8, 30)
    3.times do
      OperandChild.create!(operand_parent: matching, quantity: 1, amount: 1.25, occurred_at: time)
    end
    scope = OperandParent.where(id: [matching.id, empty.id])
    contracts = [
      [aggregate('count', 'eq', 3), aggregate('count', 'eq', '3')],
      [aggregate('sum', 'eq', 3.75, property: 'amount'), aggregate('sum', 'eq', '3.75', property: 'amount')],
      [aggregate('min', 'eq', time, property: 'occurred_at'), aggregate('min', 'eq', time.iso8601, property: 'occurred_at')],
      [aggregate('count', 'eq', 0), aggregate('count', 'eq', '0')]
    ]
    contracts.each do |native, string|
      native_ids = matches(scope, native)
      string_ids = matches(scope, string)
      abort("operand mismatch: #{native.inspect} => #{native_ids.inspect}, #{string.inspect} => #{string_ids.inspect}") unless native_ids == string_ids
    end
  RUBY

  def assignment(technician, minutes:, distance:, starts_at:)
    job = Job.create!(title: 'Aggregate operand job', duration_hours: 1, priority: 1, crew_size: 1)
    ScheduleAssignment.create!(
      technician: technician,
      job: job,
      travel_time_minutes: minutes,
      travel_distance_km: distance,
      scheduled_start: starts_at,
      scheduled_end: starts_at + 1.hour
    )
  end

  let!(:matching) do
    Technician.create!(name: 'Matching technician', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
  end
  let!(:empty) do
    Technician.create!(name: 'Empty technician', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
  end
  let(:scope) { Technician.where(id: [matching.id, empty.id]) }
  let(:starts_at) { Time.zone.parse('2026-09-07 08:30:00') }

  before { assignment(matching, minutes: 3, distance: BigDecimal('3.25'), starts_at: starts_at) }

  shared_examples 'a typed aggregate operand' do |filter|
    it 'normalizes string and native operands to the registered result type' do
      native, string = instance_exec(&filter)

      expect(apply(scope, native).ids).to contain_exactly(matching.id)
      expect(apply(scope, string).ids).to contain_exactly(matching.id)
    end
  end

  include_examples 'a typed aggregate operand', -> {
    [
      aggregate('schedule_assignments', 'eq', 1),
      aggregate('schedule_assignments', 'eq', '1')
    ]
  }

  include_examples 'a typed aggregate operand', -> {
    [
      aggregate('schedule_assignments', 'eq', BigDecimal('3.25'), aggregate: 'sum', property: 'travel_distance_km'),
      aggregate('schedule_assignments', 'eq', '3.25', aggregate: 'sum', property: 'travel_distance_km')
    ]
  }

  include_examples 'a typed aggregate operand', -> {
    [
      aggregate('schedule_assignments', 'eq', starts_at, aggregate: 'min', property: 'scheduled_start'),
      aggregate('schedule_assignments', 'eq', starts_at.iso8601, aggregate: 'min', property: 'scheduled_start')
    ]
  }

  it 'normalizes include-zero comparisons with the aggregate result type' do
    native = aggregate('schedule_assignments', 'eq', 0)
    string = aggregate('schedule_assignments', 'eq', '0')

    expect(apply(scope, native).ids).to contain_exactly(empty.id)
    expect(apply(scope, string).ids).to contain_exactly(empty.id)
  end

  it 'preserves the caller scope for normalized operands' do
    outside = Technician.create!(name: 'Outside technician', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
    assignment(outside, minutes: 3, distance: BigDecimal('3.25'), starts_at: starts_at)

    result = apply(scope.order(:id), aggregate('schedule_assignments', 'eq', '1'))

    expect(result.ids).to contain_exactly(matching.id)
  end

  it 'normalizes aggregate operands under SQLite' do
    gem_path = Gem.path.join(File::PATH_SEPARATOR)
    output, error, status = Bundler.with_unbundled_env do
      Open3.capture3(
        {'GEM_PATH' => gem_path, 'RAILS_VERSION' => ENV.fetch('RAILS_VERSION', '8.1'), 'RUBYLIB' => nil},
        RbConfig.ruby, '-Ilib', '-e', SQLITE_CONTRACT,
        chdir: File.expand_path('../../..', __dir__)
      )
    end

    expect(status).to be_success, "#{output}\n#{error}"
  end
end
