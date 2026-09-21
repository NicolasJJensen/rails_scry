# frozen_string_literal: true

require "rails_helper"

RSpec.describe "permission callback failure contracts" do
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

  it "applies callback_error_policy to property permission callbacks" do
    User.add_filter_permission(:properties) { raise "property callback failed" }
    Scry.configuration.callback_error_policy = :match_none

    expect(User.filter_property_permissions).to be_empty

    result = Scry.filter_records_by(
      records: User,
      filter: { type: "property", property: "first_name", predicate: "eq", args: ["x"] }
    ).relation
    expect(result).to be_none
  end

  it "applies callback_error_policy to association permission callbacks" do
    Organisation.add_filter_permission(:associations) { raise "association callback failed" }
    Scry.configuration.callback_error_policy = :match_none

    expect(Organisation.filter_association_permissions).to be_empty
  end

  it "applies callback_error_policy to aggregate permission callbacks" do
    Organisation.add_filter_permission(:aggregates) { raise "aggregate callback failed" }
    Scry.configuration.callback_error_policy = :match_none

    expect(Organisation.scry_permissions.allowed_aggregates(nil)).to be_empty
  end

  it "applies callback_error_policy to predicate permission callbacks" do
    User.add_filter_permission(:predicates) { raise "predicate permission callback failed" }
    Scry.configuration.callback_error_policy = :match_none

    expect(User.filter_predicate_permissions.values).to all(be_empty)
  end

  it "keeps property predicate callback failures as callback errors during execution" do
    User.add_filter_permission(:property_predicates) { raise "property predicate callback failed" }
    Scry.configuration.callback_error_policy = :match_none

    result = Scry.filter_records_by(
      records: User,
      filter: { type: "property", property: "first_name", predicate: "eq", args: ["x"] }
    )

    expect(result.relation).to be_none
    expect(result.diagnostics.map(&:code)).to include(:callback_error)
    expect(result.diagnostics.map(&:code)).not_to include(:invalid_filter)
  end

  it "keeps type predicate callback failures as callback errors during execution" do
    User.add_filter_permission(:type_predicates) { raise "type predicate callback failed" }
    Scry.configuration.callback_error_policy = :match_none

    result = Scry.filter_records_by(
      records: User,
      filter: { type: "property", property: "first_name", predicate: "eq", args: ["x"] }
    )

    expect(result.relation).to be_none
    expect(result.diagnostics.map(&:code)).to include(:callback_error)
    expect(result.diagnostics.map(&:code)).not_to include(:invalid_filter)
  end

  it "applies callback_error_policy to custom-property permission callbacks" do
    User.add_filter_permission(:custom_property_filters) { raise "custom property callback failed" }
    Scry.configuration.callback_error_policy = :match_none

    expect(User.custom_property_filters).to be_empty
  end

  it "denies the model when its permission callback fails, regardless of skip policy" do
    User.add_model_permission { raise "model callback failed" }
    Scry.configuration.callback_error_policy = :match_none
    Scry.configuration.invalid_filter_policy = :skip

    result = Scry.filter_records_by(records: User, filter: {
      type: "group", predicate: "and", filters: []
    }).relation

    expect(result).to be_none
  end

  it "re-raises discovery callback errors under the raise policy" do
    User.add_filter_permission(:properties) { raise "discovery callback failed" }

    expect { Scry.filter_capabilities(model: User) }
      .to raise_error(RuntimeError, "discovery callback failed")
  end

  it "returns empty discovery metadata under match-none" do
    User.add_filter_permission(:properties) { raise "discovery callback failed" }
    Scry.configuration.callback_error_policy = :match_none

    expect(Scry.filter_capabilities(model: User))
      .to eq(Scry.empty_information.merge(error: true))
  end

  it "logs the owning model for collection permission callback failures" do
    User.add_filter_permission(:properties) { raise "collection callback failed" }
    Scry.configuration.callback_error_policy = :match_none
    Scry.configuration.diagnostic_logging = :warn
    logger = instance_double(Logger)
    allow(Scry).to receive(:logger).and_return(logger)
    expect(logger).to receive(:warn) do |payload|
      event = JSON.parse(payload)
      expect(event["model"]).to eq("User")
      expect(event["message"]).not_to include("collection callback failed")
    end

    User.filter_capabilities(nil)
  end

  it "does not log hash permission callback failures outside a top-level operation" do
    Organisation.add_filter_permission(:aggregates) { raise "hash callback failed" }
    Scry.configuration.callback_error_policy = :match_none
    Scry.configuration.diagnostic_logging = :warn
    logger = instance_double(Logger)
    allow(Scry).to receive(:logger).and_return(logger)
    expect(logger).not_to receive(:warn)

    Organisation.scry_permissions.allowed_aggregates(nil)
  end

  it "marks discovery as errored when aggregate permission resolution fails" do
    Organisation.add_filter_permission(:aggregates) { raise "aggregate discovery failed" }
    Scry.configuration.callback_error_policy = :match_none

    info = Scry.filter_capabilities(model: Organisation)

    expect(info).to eq(Scry.empty_information.merge(error: true))
  end

  it "keeps aggregate filtering fail-closed after discovery and re-raises under raise" do
    Organisation.add_filter_permission(:aggregates) { raise "aggregate execution failed" }
    filter = {
      type: "group", predicate: "and", filters: [
        { type: "aggregate", association: "users", aggregate: "count", predicate: "eq", args: [1] }
      ]
    }
    context = Object.new

    Scry.configuration.callback_error_policy = :match_none
    Scry.filter_capabilities(model: Organisation, context: context)
    cached_forms = [
      filter,
      { type: "group", predicate: "or", filters: filter[:filters] },
      { type: "group", predicate: "and", negate: true, filters: filter[:filters] },
      { type: "group", predicate: "and", filters: [
        { type: "group", predicate: "or", filters: filter[:filters] }
      ] }
    ]
    cached_forms.each do |definition|
      result = Scry.filter_records_by(records: Organisation, filter: definition, context:)

      expect(result).to be_failed
      expect(result.relation).to be_none
      expect(result.diagnostics.map(&:category)).to include(:callback_error)
      expect(result.diagnostics.map(&:code)).to include(:callback_error)
    end

    Scry.clear_thread_caches!
    Scry.configuration.callback_error_policy = :raise
    expect {
      Scry.filter_records_by(records: Organisation, filter:, context: context).relation
    }.to raise_error(RuntimeError, "aggregate execution failed")
  end
end
