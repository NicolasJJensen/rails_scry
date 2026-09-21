# frozen_string_literal: true

require_relative "support"
require "stringio"

RSpec.describe "Root permission failure diagnostics", :interoperability do
  %i[skip match_none].each do |mode|
    it "denies the relation and reports a redacted callback failure in #{mode} mode" do
      User.add_model_permission { raise ArgumentError, "private-context-value" }
      Scry.configuration.invalid_filter_policy = mode
      Scry.configuration.callback_error_policy = :match_none
      stream = StringIO.new
      Scry.configuration.logger = Logger.new(stream)

      results = 2.times.map { Scry.filter_records_by(records: User, filter: group) }

      results.each do |result|
        expect(result.relation).to be_empty
        expect(result.diagnostics).to contain_exactly(
          have_attributes(category: :callback_error, code: :callback_error, path: [])
        )
        expect(result.diagnostics.first.message).to include("model permission callback failed (ArgumentError)")
        expect(result.diagnostics.first.message).not_to include("private-context-value")
      end
      expect(stream.string).not_to include("private-context-value")
    end
  end

  it "preserves the callback failure policy during validation" do
    User.add_model_permission { raise ArgumentError, "private-context-value" }
    Scry.configuration.invalid_filter_policy = :raise
    Scry.configuration.callback_error_policy = :match_none

    expect(Scry.validate_filter(model: User, filter: group))
      .to contain_exactly(have_attributes(category: :callback_error, code: :callback_error))
    expect(Scry.configuration.invalid_filter_policy).to eq(:raise)
    expect(Scry.configuration.callback_error_policy).to eq(:match_none)
  end

  it "keeps strict execution failures as FilterError" do
    User.add_model_permission { raise ArgumentError, "private-context-value" }
    Scry.configuration.invalid_filter_policy = :raise
    expect do
      Scry.filter_records_by(records: User, filter: group)
    end.to raise_error(ArgumentError, /private-context-value/)
  end
end
