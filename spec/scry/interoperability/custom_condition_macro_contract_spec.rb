# frozen_string_literal: true

require_relative "support"

RSpec.describe "Custom property condition macro contract", interoperability: true do
  def custom_property_error
    yield
    raise "expected custom property definition to fail"
  rescue Scry::FilterError => error
    error
  end

  it "rejects an incompatible predicate declaration during resolution" do
    User.add_custom_property_filter(type: :string, predicates: [:eq]) do
      {flag: group(property("active", "eq_true"))}
    end

    error = custom_property_error { User.filter_predicate_permissions }

    expect(error.message).to match(/custom property metadata type must be boolean/i)
  end

  it "rejects ordinary numeric and string predicates for a custom condition macro" do
    User.add_custom_property_filter(type: :boolean, predicates: %i[eq matches]) do
      {flag: group(property("active", "eq_true"))}
    end

    error = custom_property_error { User.filter_predicate_permissions }

    expect(error.message).to match(/custom property.*eq_true.*eq_false|eq_true.*eq_false.*custom property/i)
  end

  it "keeps an explicitly empty predicate whitelist denied" do
    User.add_custom_property_filter(type: :boolean, predicates: []) do
      {flag: group(property("active", "eq_true"))}
    end

    expect(User.filter_predicate_permissions[:flag]).to eq([])
  end

  it "rejects a custom zero-arity predicate other than the truth predicates" do
    Scry.configuration.register_predicate(
      :zero_boolean,
      compounds: false,
      types: [:boolean]
    ) { |attribute| attribute.eq(true) }
    User.add_custom_property_filter(type: :boolean, predicates: [:zero_boolean]) do
      {flag: group(property("active", "eq_true"))}
    end

    error = custom_property_error { User.filter_predicate_permissions }

    expect(error.message).to match(/custom property.*eq_true.*eq_false|eq_true.*eq_false.*custom property/i)
  end

  it "defaults boolean custom properties to the two truth predicates" do
    User.add_custom_property_filter(type: :boolean) do
      {flag: group(property("active", "eq_true"))}
    end

    expect(User.filter_predicate_permissions[:flag]).to contain_exactly(:eq_true, :eq_false)
  end

  it "does not let property permissions expand the default truth predicate set" do
    Scry.configuration.register_predicate(
      :zero_boolean,
      compounds: false,
      types: [:boolean]
    ) { |attribute| attribute.eq(true) }
    User.add_custom_property_filter(type: :boolean) do
      {flag: group(property("active", "eq_true"))}
    end
    User.add_filter_permission(:property_predicates) do
      {flag: [:zero_boolean]}
    end

    expect(User.filter_predicate_permissions[:flag]).to contain_exactly(:eq_true, :eq_false)
  end

  it "executes both truth branches and retains both in discovery" do
    active = create(:user, active: true)
    inactive = create(:user, active: false)
    User.add_custom_property_filter(type: :boolean) do
      {flag: group(property("active", "eq_true"))}
    end

    expect(User.filter_predicate_permissions[:flag]).to contain_exactly(:eq_true, :eq_false)
    expect(apply(User.where(id: [active.id, inactive.id]), property("flag", "eq_true")).ids)
      .to eq([active.id])
    expect(apply(User.where(id: [active.id, inactive.id]), property("flag", "eq_false")).ids)
      .to eq([inactive.id])
  end
end
