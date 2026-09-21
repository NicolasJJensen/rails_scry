# frozen_string_literal: true

RSpec.shared_examples 'association operand contracts' do
  it 'rejects a missing operand for a required association predicate and reports the filter path' do
    Scry.configuration.invalid_filter_policy = :skip
    Scry.configuration.register_predicate(
      :requires_owner_operand,
      types: [:single_association], applies_to: [:association], compounds: false
    ) { |_attribute, _value| Arel::Nodes.build_quoted(true) }
    @child.add_filter_permission(:predicates, list_type: :includelist) { [:requires_owner_operand] }
    @child.scry_permissions.clear_caches!
    node = {type: 'association', association: 'owner', predicate: 'requires_owner_operand'}

    result = Scry.filter_records_by(records: @child, filter: boundary_group(node))

    expect(result.diagnostics.map(&:message)).to include(match(/expects 1 argument/))
    expect(result.diagnostics.map(&:path)).to include([:filters, 0])
  end

  it 'rejects equality operands instead of reinterpreting them as membership' do
    Scry.configuration.invalid_filter_policy = :skip
    node = {type: 'association', association: 'owner', predicate: 'eq', args: [nil]}

    result = Scry.filter_records_by(records: @child, filter: boundary_group(node))
    expect(result.diagnostics.map(&:message)).to include(match(/association predicate eq is unsupported/))
  end

  it 'preserves a scalar operand through a custom association predicate pipeline' do
    received = []
    Scry.configuration.register_predicate(
      :has_at_least, types: [:many_association], applies_to: [:association], compounds: false,
      validator: lambda { |value|
        received << [:validator, value]
        raise ArgumentError, 'expected an Integer' unless value.is_a?(Integer)

        value
      },
      formatter: ->(value) { received << [:formatter, value]; value }
    ) do |attribute, value|
      received << [:predicate, value]
      query = Scry::AssociationQuery.for_attribute(attribute)
      query.owner_count_at_least(query.eligible_child_relation, minimum: value)
    end
    @owner.add_filter_transform(:children, only: [:has_at_least], on: [:value]) do |value, _context|
      received << [:transform, value]
      value
    end

    result = Scry.filter_records_by(records: @owner, filter: boundary_group(boundary_association('has_at_least', 2)))

    expect(result.relation.ids).to eq([@first.id])
    expect(result.diagnostics).to be_empty
    expect(received).to eq([[:validator, 2], [:transform, 2], [:formatter, 2], [:predicate, 2]])
  end

  it 'passes nil to the validator of a zero-operand association predicate' do
    received = []
    Scry.configuration.register_predicate(
      :has_children, types: [:many_association], applies_to: [:association], compounds: false,
      validator: ->(value) { received << value; value }
    ) do |attribute|
      query = Scry::AssociationQuery.new(@owner, attribute.name)
      query.membership(query.joined_relation)
    end

    node = {type: 'association', association: 'children', predicate: 'has_children'}
    expect(boundary_filter(node).ids).to contain_exactly(@first.id, @second.id)
    expect(received).to eq([])
  end

  it 'retains scalar ID normalization for a custom set-valued association predicate' do
    received = []
    Scry.configuration.register_predicate(
      :has_requested_children, types: [:many_association], applies_to: [:association], compounds: false,
      validator: ->(value) { received << value; value }
    ) do |attribute, value|
      Scry::AssociationQuery.for_attribute(attribute).has_any(value)
    end

    expect(boundary_filter(boundary_association('has_requested_children', @a.id)).ids).to eq([@first.id])
    expect(received).to eq([@a.id])
  end

  it 'preserves scoped relation operands for custom association predicates' do
    received = []
    Scry.configuration.register_predicate(
      :has_matching_children, types: [:many_association], applies_to: [:association], compounds: false,
      validator: ->(value) { received << value; value }
    ) do |attribute, value|
      Scry::AssociationQuery.for_attribute(attribute).has_any(value)
    end
    node = boundary_association('has_matching_children', @child.where(name: 'a'))

    expect(boundary_filter(node).ids).to eq([@first.id])
    expect(received.one?).to be(true)
    expect(received.first).to be_a(ActiveRecord::Relation)
    expect(received.first.ids).to eq([@a.id])
  end
end
