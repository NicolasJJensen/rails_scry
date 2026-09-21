# frozen_string_literal: true

RSpec.shared_examples 'discovery contracts' do
  it 'formats each compound textual aggregate operand independently' do
    @a.update!(name: 'a_b%c')
    @c.update!(name: 'c%d')

    matches_any = {
      type: 'aggregate', association: 'children', aggregate: 'min', property: 'name',
      predicate: 'matches_any', args: [['a_', 'c%']]
    }
    matches_all = matches_any.merge(predicate: 'matches_all', args: [['a_', 'b%']])

    expect(boundary_filter(matches_any).ids).to contain_exactly(@first.id, @second.id)
    expect(boundary_filter(matches_all).ids).to eq([@first.id])
  end

  it 'requires an array for compound textual aggregate predicates' do
    node = {
      type: 'aggregate', association: 'children', aggregate: 'min', property: 'name',
      predicate: 'matches_any', args: ['a']
    }

    expect { boundary_filter(node) }.to raise_error(Scry::FilterError, /Array/)
  end

  it 'requires a scalar for scalar textual aggregate predicates' do
    node = {
      type: 'aggregate', association: 'children', aggregate: 'min', property: 'name',
      predicate: 'matches', args: [['a']]
    }

    expect { boundary_filter(node) }.to raise_error(Scry::FilterError, /scalar operand/)
  end

  it 'exposes predicates for an aggregate-only capability in strict mode' do
    Scry.configuration.strict = true
    @child.add_filter_permission(:properties, list_type: :whitelist) { [] }
    @owner.add_filter_permission(:associations, list_type: :includelist) { [:children] }
    @owner.add_filter_permission(:aggregates, list_type: :includelist) { { children: { count: true } } }
    @owner.add_filter_permission(:predicates, list_type: :includelist) { [:gteq] }

    info = Scry.filter_capabilities(model: @owner)

    expect(info[:aggregates].dig('children', 'count')).to be(true)
    expect(info[:predicates]).to have_key(:gteq)
    expect(info[:predicates][:gteq]).to include(arguments: {min: 1, max: 1}, parameters: a_kind_of(Array), label: a_kind_of(String))
    expect(info[:aggregate_predicates].dig('children', 'count')).to include(:gteq)
    expect(boundary_filter({ type: 'aggregate', association: 'children', aggregate: 'count', predicate: 'gteq', args: [2] }).ids).to eq([@first.id])
  end

  it 'describes aggregate metadata and property-result predicates by field' do
    @owner.add_filter_permission(:aggregates, list_type: :includelist) do
      { children: { count: true, min: [:amount, :name] } }
    end
    @owner.add_filter_permission(:predicates, list_type: :whitelist) { [:eq, :gteq, :matches] }

    info = Scry.filter_capabilities(model: @owner)

    expect(info[:aggregate_metadata].dig('children', 'count')).to include(
      label: a_kind_of(String), result_type: 'integer', property: false
    )
    expect(info[:aggregate_metadata].dig('children', 'min')).to include(
      label: a_kind_of(String), result_type: 'property', property: true
    )
    expect(info[:aggregate_metadata].dig('children', 'min', :result_types)).to include(
      'amount' => 'integer', 'name' => 'string'
    )
    expect(info[:aggregate_predicates].dig('children', 'count')).to include(:eq, :gteq)
    expect(info[:aggregate_predicates].dig('children', 'min', 'amount')).to include(:eq, :gteq)
    expect(info[:aggregate_predicates].dig('children', 'min', 'amount')).not_to include(:matches)
    expect(info[:aggregate_predicates].dig('children', 'min', 'name')).to include(:eq, :matches)
    expect(info[:predicates]).not_to have_key(:not_eq)
  end

  it 'returns the same discovery schema through the model convenience API' do
    expect(@owner.filter_capabilities).to eq(Scry.filter_capabilities(model: @owner))
  end

  it 'keeps denied model discovery empty' do
    @owner.add_model_permission { false }

    info = Scry.filter_capabilities(model: @owner)

    expect(info).to eq(Scry.empty_information)
  end

  it 'keeps discovery metadata immutable' do
    info = Scry.filter_capabilities(model: @owner)

    expect { info[:aggregate_metadata][:changed] = true }.to raise_error(FrozenError)
    expect { info[:aggregate_predicates][:changed] = true }.to raise_error(FrozenError)
  end

  it 'refreshes aggregate metadata after child permissions change' do
    @owner.add_filter_permission(:aggregates, list_type: :includelist) { { children: { min: :all } } }
    before = Scry.filter_capabilities(model: @owner)
    expect(before[:aggregate_metadata].dig('children', 'min', :result_types)).to include('amount' => 'integer')

    @child.add_filter_permission(:properties, list_type: :excludelist) { [:amount] }
    after = Scry.filter_capabilities(model: @owner)

    expect(after[:aggregate_metadata].dig('children', 'min', :result_types)).not_to have_key('amount')
    expect(after[:aggregate_predicates].dig('children', 'min')).not_to have_key('amount')
  end

  it 'uses the requested locale in aggregate labels' do
    original_backend = I18n.backend
    original_locales = I18n.available_locales
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = (original_locales + [:xx]).uniq
    I18n.backend.store_translations(:xx, scry: { aggregates: { count: 'Anzahl' } })
    info = Scry.filter_capabilities(model: @owner, locale: :xx)

    expect(info[:aggregate_metadata].dig('children', 'count', :label)).to eq('Anzahl')
  ensure
    I18n.backend = original_backend if original_backend
    I18n.available_locales = original_locales if original_locales
  end

  it 'filters aggregate metadata by the active adapter' do
    Scry.configuration.register_aggregate(
      :sqlite_discovery_only, types: [:all], result_type: :integer,
      property: false, adapters: [:sqlite3]
    ) { |attribute, distinct| attribute.count(distinct) }
    @owner.add_filter_permission(:aggregates, list_type: :includelist) do
      { children: { sqlite_discovery_only: true } }
    end

    info = Scry.filter_capabilities(model: @owner)

    if Scry::Compatibility.adapter(@owner) == 'sqlite3'
      expect(info[:aggregate_metadata].dig('children', 'sqlite_discovery_only')).to be_present
    else
      expect(info[:aggregate_metadata].dig('children', 'sqlite_discovery_only')).to be_nil
    end
  end

  it 'invalidates aggregate predicate discovery for different contexts' do
    actor = Struct.new(:admin).new(true)
    guest = Struct.new(:admin).new(false)
    @owner.add_filter_permission(:aggregates, list_type: :includelist) { { children: { count: true } } }
    @owner.add_filter_permission(:predicates, list_type: :whitelist) { |context| context.admin ? [:gteq] : [] }

    expect(Scry.filter_capabilities(model: @owner, context: actor)[:aggregate_predicates].dig('children', 'count')).to include(:gteq)
    expect(Scry.filter_capabilities(model: @owner, context: guest)[:aggregate_predicates].dig('children', 'count')).not_to include(:gteq)

    @owner.add_filter_permission(:predicates, list_type: :excludelist) { [:gteq] }
    expect(Scry.filter_capabilities(model: @owner, context: actor)[:aggregate_predicates].dig('children', 'count')).not_to include(:gteq)
  end
end
