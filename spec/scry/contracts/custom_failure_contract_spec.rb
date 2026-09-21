# frozen_string_literal: true

require "rails_helper"

# rubocop:disable Metrics/BlockLength
RSpec.describe "custom protected failure results" do
  def group(*children, negate: false)
    { type: :group, predicate: :and, filters: children, negate: }
  end

  def custom_failure(category)
    { type: :custom_protected_failure, category: }
  end

  around do |example|
    Scry.configuration.with_temporary_settings do |config|
      original_scopes = User.scry_scopes
      config.register_filter(:custom_protected_failure, custom_failure_filter)
      example.run
    ensure
      User.scry_scopes = original_scopes
    end
  end

  let(:custom_failure_filter) do
    Class.new(Scry::Filters::Base) do
      def apply
        failure(
          "Scry: custom #{@filter[:category]} failure",
          category: @filter[:category],
          code: @filter[:category]
        )
      end
    end
  end

  %i[callback_error scope_error].each do |category|
    %i[skip].each do |policy|
      it "fails closed for a root #{category} result under #{policy}" do
        record = create(:user)
        Scry.configuration.invalid_filter_policy = policy

        result = Scry.filter_records_by(
          records: User.where(id: record.id),
          filter: custom_failure(category)
        )

        expect(result).to be_failed
        expect(result.relation).to be_empty
        expect(result.diagnostics).to contain_exactly(have_attributes(category:, code: category, path: []))
      end

      it "fails closed for a partial group #{category} result under #{policy}" do
        record = create(:user, first_name: "#{category}-#{policy}")
        Scry.configuration.invalid_filter_policy = policy

        result = Scry.filter_records_by(
          records: User.where(id: record.id),
          filter: group(
            { type: :property, property: :first_name, predicate: :eq, args: [record.first_name] },
            custom_failure(category)
          )
        )

        expect(result).to be_failed
        expect(result.relation).to be_empty
        expect(result.diagnostics).to contain_exactly(
          have_attributes(category:, code: category, path: [:filters, 1])
        )
      end
    end

    it "attaches an empty #{category} result when raise policy raises" do
      record = create(:user)
      Scry.configuration.invalid_filter_policy = :raise

      expect do
        Scry.filter_records_by(
          records: User.where(id: record.id),
          filter: custom_failure(category)
        )
      end.to raise_error(Scry::FilterError) { |error|
        expect(error.result).to be_failed
        expect(error.result.relation).to be_empty
        expect(error.result.diagnostics).to contain_exactly(have_attributes(category:, code: category))
      }
    end

    it "fails closed for a nested negated #{category} group" do
      matching = create(:user, first_name: "nested-#{category}")
      unmatched = create(:user, first_name: "other-#{category}")
      Scry.configuration.invalid_filter_policy = :skip

      result = Scry.filter_records_by(
        records: User.where(id: [matching.id, unmatched.id]),
        filter: group(
          group(
            { type: :property, property: :first_name, predicate: :eq, args: [matching.first_name] },
            custom_failure(category)
          ),
          negate: true
        )
      )

      expect(result).to be_failed
      expect(result.relation).to be_empty
      expect(result.diagnostics).to contain_exactly(
        have_attributes(category:, code: category, path: [:filters, 0, :filters, 1])
      )
    end
  end

  it "keeps a mandatory root scope when a custom scope failure occurs" do
    allowed = create(:user, active: true)
    create(:user, active: false)
    User.add_filter_scope { |_context| where(active: true) }

    result = Scry.filter_records_by(
      records: User.where(id: User.where(active: [true, false]).select(:id)),
      filter: custom_failure(:scope_error)
    )

    expect(result).to be_failed
    expect(result.relation).to be_empty
    expect(result.diagnostics).to contain_exactly(have_attributes(category: :scope_error))
    expect(allowed).to be_persisted
  end

  it "keeps ordinary invalid-filter failures as the skip identity" do
    record = create(:user)
    Scry.configuration.invalid_filter_policy = :skip

    result = Scry.filter_records_by(
      records: User.where(id: record.id),
      filter: custom_failure(:invalid_filter)
    )

    expect(result).to be_failed
    expect(result.relation).to contain_exactly(record)
    expect(result.diagnostics).to contain_exactly(have_attributes(category: :invalid_filter, code: :invalid_filter))
  end
end
# rubocop:enable Metrics/BlockLength
