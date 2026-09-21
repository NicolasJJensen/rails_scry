# frozen_string_literal: true

require "rails_helper"

RSpec.describe "callback failure policy" do
  around do |example|
    Scry.configuration.with_temporary_settings { |config| example.run }
  end

  let(:filter) do
    {
      type: "group",
      predicate: "and",
      filters: [
        { type: "property", property: "first_name", predicate: "callback_failure", args: ["Alice"] }
      ]
    }
  end

  before do
    Scry.configuration.register_predicate(
      :callback_failure,
      types: [:textual],
      compounds: false
    ) do |_attribute, _value|
      raise "predicate callback failed"
    end
  end

  it "raises callback exceptions by default" do
    expect {
      Scry.filter_records_by(records: User.all, filter: filter).relation
    }.to raise_error(RuntimeError, "predicate callback failed")
  end

  it "returns no records when callback errors use the match-none policy" do
    Scry.configuration.callback_error_policy = :match_none

    result = Scry.filter_records_by(records: User.all, filter: filter)

    expect(result.relation).to be_none
    expect(result.diagnostics.map(&:code)).to include(:callback_error)
  end

  it "keeps invalid input policy separate from callback failure policy" do
    Scry.configuration.invalid_filter_policy = :skip

    malformed = {
      type: "group",
      predicate: "and",
      filters: [{ type: "property", property: "first_name" }]
    }

    result = Scry.filter_records_by(records: User.all, filter: malformed)

    expect(result.relation).not_to be_none
    expect(result.diagnostics.map(&:category)).to include(:invalid_filter)
    expect(result.diagnostics.map(&:code)).to include(:missing_predicate)
  end
end
