# frozen_string_literal: true

RSpec.shared_examples 'custom condition contracts' do
  it 'executes a boolean custom condition through eq_true' do
    @owner.add_custom_property_filter(type: :boolean) do
      {high_amount: boundary_group(boundary_property('amount', 'gt', 10))}
    end

    expect(boundary_filter(boundary_property('high_amount', 'eq_true', nil)).ids).to eq([@second.id])
  end

  it 'keeps an explicitly empty custom predicate list denied' do
    @owner.add_custom_property_filter(type: :boolean, predicates: []) do
      {high_amount: boundary_group(boundary_property('amount', 'gt', 10))}
    end

    expect(@owner.filter_predicate_permissions[:high_amount]).to eq([])
    expect { boundary_filter(boundary_property('high_amount', 'eq_true', nil)) }
      .to raise_error(Scry::FilterError, /invalid predicate|permission/i)
  end

  it 'rejects a value-taking predicate for a custom condition' do
    @owner.add_custom_property_filter(type: :boolean, predicates: [:eq]) do
      {high_amount: boundary_group(boundary_property('amount', 'gt', 10))}
    end

    expect { @owner.filter_predicate_permissions }
      .to raise_error(Scry::FilterError, /eq_true.*eq_false|custom property/i)
  end
end
