# frozen_string_literal: true

require "rails_helper"

RSpec.describe "configuration policy contracts" do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings { |settings| example.run }
  end

  it "uses explicit independent defaults for invalid input, callback errors, and diagnostics" do
    settings = Scry.configuration

    expect(settings.invalid_filter_policy).to eq(:skip)
    expect(settings.callback_error_policy).to eq(:raise)
    expect(settings.diagnostic_logging).to eq(:silent)
  end

  it "accepts string policy names and rejects unknown values" do
    settings = Scry.configuration
    settings.invalid_filter_policy = "match_none"
    settings.callback_error_policy = "match_none"
    settings.diagnostic_logging = "warn"

    expect(settings.invalid_filter_policy).to eq(:match_none)
    expect(settings.callback_error_policy).to eq(:match_none)
    expect(settings.diagnostic_logging).to eq(:warn)

    expect { settings.invalid_filter_policy = :ignore }.to raise_error(ArgumentError)
    expect { settings.invalid_filter_policy = :reject }.to raise_error(ArgumentError)
    expect { settings.invalid_filter_policy = :warning }.to raise_error(ArgumentError)
    expect { settings.callback_error_policy = :skip }.to raise_error(ArgumentError)
    expect { settings.diagnostic_logging = :raise }.to raise_error(ArgumentError)
  end

  it "does not log an invalid request when diagnostic logging is silent" do
    settings = Scry.configuration
    settings.diagnostic_logging = :silent
    expect(Scry.logger).not_to receive(:warn)

    Scry.filter_records_by(
      records: User,
      filter: { type: "property", property: "missing_property", predicate: "eq", args: ["x"] }
    )
  end

  it "logs diagnostics independently from the invalid-input outcome" do
    settings = Scry.configuration
    settings.invalid_filter_policy = :skip
    settings.diagnostic_logging = :warn
    expect(Scry.logger).to receive(:warn).at_least(:once)

    result = Scry.filter_records_by(
      records: User,
      filter: { type: "property", property: "missing_property", predicate: "eq", args: ["x"] }
    )

    expect(result.relation).to be_a(ActiveRecord::Relation)
  end
end
