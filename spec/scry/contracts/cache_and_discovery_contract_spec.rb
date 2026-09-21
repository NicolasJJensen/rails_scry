# frozen_string_literal: true

require "rails_helper"

RSpec.describe "permission cache and discovery contracts" do
  around(:each) do |example|
    original_user = User.scry_permissions.deep_dup(klass: User)
    original_organisation = Organisation.scry_permissions.deep_dup(klass: Organisation)
    Scry.configuration.with_temporary_settings { example.run }
  ensure
    User.scry_permissions = original_user
    User.scry_permissions.clear_caches!
    Organisation.scry_permissions = original_organisation
    Organisation.scry_permissions.clear_caches!
  end

  it "reuses a permission result for the same request context" do
    calls = 0
    context = Struct.new(:admin).new(true)
    User.add_filter_permission(:properties) do |current_context|
      calls += 1
      current_context.admin ? [:first_name] : []
    end

    expect(User.filter_property_permissions(context)).to include(:first_name)
    expect(User.filter_property_permissions(context)).to include(:first_name)
    expect(calls).to eq(1)
  end

  it "keeps aggregate metadata and executable predicates aligned after a child field is denied" do
    User.add_filter_permission(:properties, list_type: :excludelist) { [:first_name] }
    Organisation.add_filter_permission(:aggregates, list_type: :includelist) do
      { users: { min: [:first_name, :last_name] } }
    end

    info = Organisation.filter_capabilities
    metadata = info[:aggregate_metadata].dig("users", "min", :result_types)
    predicates = info[:aggregate_predicates].dig("users", "min")

    expect(metadata).not_to have_key("first_name")
    expect(predicates).not_to have_key("first_name")
    expect(metadata).to have_key("last_name")
    expect(predicates).to have_key("last_name")
  end

  it "does not expose a denied target association in any discovery section" do
    User.add_model_permission { false }

    info = Organisation.filter_capabilities

    expect(info[:associations].map { |entry| entry[:key] }).not_to include("users")
    expect(info[:aggregates]).not_to have_key("users")
    expect(info[:aggregate_metadata]).not_to have_key("users")
    expect(info[:aggregate_predicates]).not_to have_key("users")
  end
end
