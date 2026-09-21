# frozen_string_literal: true

RSpec.shared_examples 'computed selection contracts' do
  it 'filters a structured arithmetic expression' do
    node = {
      type: 'computed',
      expression: {operator: 'subtract', operands: [{property: 'amount'}, {literal: 1}]},
      predicate: 'gteq', args: [10]
    }
    expect(boundary_filter(node).ids).to eq([@second.id])
  end

  it 'orders a group by a structured expression before applying its limit' do
    node = {
      type: 'group', predicate: 'and', filters: [boundary_property('amount', 'gteq', 0)],
      order: [{expression: {operator: 'add', operands: [{property: 'amount'}, {literal: 1}]}, direction: 'desc'}],
      limit: 1
    }
    expect(boundary_filter(*node[:filters], order: node[:order], limit: node[:limit]).ids).to eq([@second.id])
  end

  it 'evaluates nested computed expressions against an aliased derived source' do
    source_table = @owner.arel_table
    source = source_table.project(
      source_table[:id],
      (source_table[:amount] * 2).as('amount')
    ).as('computed_boundary_source')
    records = @owner.select(:id, :amount).from(source)
    node = {
      type: 'computed',
      expression: {
        operator: 'multiply',
        operands: [
          {operator: 'add', operands: [{property: 'amount'}, {literal: 1}]},
          {literal: 2}
        ]
      },
      predicate: 'eq', args: [82]
    }

    expect(records.pluck(:amount)).to contain_exactly(10, 40)
    expect(boundary_filter(node, records: records).ids).to eq([@second.id])
  end

  it 'passes formatted Ruby operands to ordinary custom predicates for properties and computed expressions' do
    seen = []
    Scry.configuration.register_predicate(
      :boundary_custom_integer_eq, types: [:numerical], applies_to: %i[property computed], compounds: false,
      formatter: ->(value) { Integer(value) }
    ) do |attribute, value|
      seen << value
      attribute.eq(value)
    end
    @owner.add_filter_permission(:property_predicates) do
      {amount: [:boundary_custom_integer_eq]}
    end

    property = boundary_property('amount', 'boundary_custom_integer_eq', '20')
    computed = {
      type: 'computed', expression: {property: 'amount'},
      predicate: 'boundary_custom_integer_eq', args: ['20']
    }

    expect(boundary_filter(property).ids).to eq([@second.id])
    expect(boundary_filter(computed).ids).to eq([@second.id])
    expect(seen).to eq([20, 20])
    expect(seen).to all(be_a(Integer))
  end

  it 'orders a group by a computed expression against an aliased derived source' do
    source_table = @owner.arel_table
    source = source_table.project(
      source_table[:id],
      (source_table[:amount] * 2).as('amount')
    ).as('ordered_boundary_source')
    records = @owner.select(:id, :amount).from(source)
    node = {
      type: 'group', predicate: 'and', filters: [boundary_property('id', 'gteq', 0)],
      order: [{
        expression: {operator: 'add', operands: [{property: 'amount'}, {literal: 1}]},
        direction: 'desc'
      }]
    }

    expect(boundary_filter(*node[:filters], order: node[:order], records: records).ids)
      .to eq([@second.id, @first.id])
  end

  it 'orders a nested group selection using values from an aliased derived source' do
    source_table = @owner.arel_table
    source = source_table.project(
      source_table[:id],
      (source_table[:amount] * -1).as('amount')
    ).as('nested_ordered_boundary_source')
    records = @owner.select(:id, :amount).from(source)
    node = {
      type: 'group', predicate: 'and', filters: [{
        type: 'group', predicate: 'and', filters: [boundary_property('id', 'gteq', 0)],
        order: [{property: 'amount', direction: 'desc'}], limit: 1
      }]
    }

    expect(records.pluck(:amount)).to contain_exactly(-@first.amount, -@second.amount)
    expect(boundary_filter(*node[:filters], records: records).ids).to eq([@first.id])
  end

  it 'preserves fractional division in the standalone adapter harness' do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_division, temporary: connection.adapter_name != 'Mysql2') do |table|
      table.numeric :numerator
      table.numeric :denominator
    end
    stub_const('BoundaryDivision', Class.new(ActiveRecord::Base))
    BoundaryDivision.table_name = 'af_boundary_division'
    BoundaryDivision.include(Scry::Filterable)
    BoundaryDivision.create!(numerator: 7.5, denominator: 2)

    filter = {
      type: 'computed',
      expression: {operator: 'divide', operands: [{property: 'numerator'}, {property: 'denominator'}]},
      predicate: 'eq', args: [3.75]
    }
    expect(Scry.filter_records_by(records: BoundaryDivision, filter: {type: 'group', predicate: 'and', filters: [filter]}).relation.count).to eq(1)
  ensure
    connection&.drop_table(:af_boundary_division, if_exists: true)
  end
end
