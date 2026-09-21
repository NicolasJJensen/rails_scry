# frozen_string_literal: true

require 'rails_helper'
require_relative '../interoperability/temporary_table_support'

RSpec.describe 'filter results', :interoperability do
  def group(*children, predicate: 'and')
    {type: 'group', predicate:, filters: children}
  end

  def property(name, predicate, value)
    {type: 'property', property: name, predicate:, args: [value]}
  end

  let(:invalid) { property('not_permitted', 'eq', 'value') }

  it 'constructs rich diagnostics through failure and rejects incoherent statuses' do
    relation = User.all

    result = Scry::Result.failure(
      relation:,
      category: :permission_denied,
      code: :property_denied,
      path: [:filters, 0],
      message: 'Scry: property is not allowed'
    )

    expect(result).to be_failed
    expect(result.diagnostics.first.to_h).to eq(
      category: :permission_denied,
      code: :property_denied,
      path: [:filters, 0],
      message: 'Scry: property is not allowed'
    )
    expect {
      Scry::Result.new(status: :failed, relation:, diagnostics: [])
    }.to raise_error(ArgumentError, /must include diagnostics/)
    expect {
      Scry::Result.new(status: :success, relation:, diagnostics: result.diagnostics)
    }.to raise_error(ArgumentError, /cannot include diagnostics/)
    expect {
      Scry::Result.new(status: :success, relation: User)
    }.to raise_error(ArgumentError, /relation must be an ActiveRecord::Relation/)
  end

  it 'returns an immutable successful result for a valid filter' do
    user = create(:user, first_name: 'Result match')

    result = Scry.filter_records_by(
      records: User,
      filter: group(property('first_name', 'eq', 'Result match'))
    )

    expect(result).to be_success
    expect(result.relation).to contain_exactly(user)
    expect(result.diagnostics).to be_empty
    expect(result).to be_frozen
  end

  it 'returns a partial result when a group has valid and invalid children' do
    user = create(:user, first_name: 'Partial match')

    result = Scry.filter_records_by(
      records: User,
      filter: group(property('first_name', 'eq', 'Partial match'), invalid)
    )

    expect(result).to be_partial
    expect(result.relation).to contain_exactly(user)
    expect(result.diagnostics.map(&:code)).to include(:property_denied)
    expect(result.diagnostics.map(&:path)).to include([:filters, 1])
  end

  it 'replaces only the relation while preserving immutable result state' do
    relation = User.all
    replacement = User.where(id: -1)
    diagnostic = Scry::Diagnostic.new(
      category: :invalid_filter,
      code: :custom_invalid,
      path: [:filters, 0],
      message: 'invalid'
    )

    {
      success: Scry::Result.success(relation),
      partial: Scry::Result.partial(relation, diagnostics: [diagnostic]),
      failed: Scry::Result.new(status: :failed, relation:, diagnostics: [diagnostic])
    }.each do |status, result|
      replaced = result.with_relation(replacement)

      expect(replaced).to be_frozen
      expect(replaced.status).to eq(status)
      expect(replaced.relation).to eq(replacement)
      expect(replaced.diagnostics).to eq(result.diagnostics)
      expect(result.relation).to eq(relation)
    end

    expect { Scry::Result.success(relation).with_relation(User) }
      .to raise_error(ArgumentError, /relation must be an ActiveRecord::Relation/)
  end

  it 'returns a failed result with the skip identity when every group child is invalid' do
    user = create(:user)

    result = Scry.filter_records_by(records: User.where(id: user.id), filter: group(invalid))

    expect(result).to be_failed
    expect(result.relation).to contain_exactly(user)
    expect(result.diagnostics.first.category).to eq(:permission_denied)
  end

  it 'raises with the completed result when the invalid filter policy is raise' do
    Scry.configuration.with_temporary_settings do |settings|
      settings.invalid_filter_policy = :raise

      expect {
        Scry.filter_records_by(records: User, filter: group(invalid))
      }.to raise_error(Scry::FilterError) { |error|
        expect(error.result).to be_failed
        expect(error.result.diagnostics.first.code).to eq(:property_denied)
      }
    end
  end

  it 'gives custom filters the caller derived source through Base helpers' do
    filter_class = Class.new(Scry::Filters::Base) do
      def apply
        success(source_relation.where(source_attribute(:amount).eq(@filter[:value])))
      end
    end
    stub_const('ResultContracts::DerivedSourceFilter', filter_class)
    Scry.configuration.register_filter(:derived_source_test, filter_class)

    with_temporary_table('af_result_derived_source', 'id bigint PRIMARY KEY, amount bigint NOT NULL') do |table|
      record = temporary_model('InteroperabilityTemporary::ResultDerivedSource', table)
      first = record.create!(id: 1, amount: 7)
      record.create!(id: 2, amount: 2)
      source_table = record.arel_table
      source = source_table.project(source_table[:id], (source_table[:amount] * 2).as('amount')).as('result_source')
      records = record.select(:id, :amount).from(source)

      result = Scry.filter_records_by(
        records:,
        filter: {type: 'derived_source_test', value: 14}
      )

      expect(result).to be_success
      expect(result.relation.ids).to eq([first.id])
    end
  end

  describe 'custom result diagnostics' do
    around do |example|
      Scry.configuration.with_temporary_settings { example.run }
    end

    let(:diagnostic_filter) do
      Class.new(Scry::Filters::Base) do
        def apply
          Scry::Result.failure(
            relation: @scope.none,
            category: :invalid_filter,
            code: :custom_invalid,
            path: diagnostic_path,
            message: 'Scry: custom filter rejected this request'
          )
        end
      end
    end

    before do
      stub_const('ResultContracts::DiagnosticFilter', diagnostic_filter)
      Scry.configuration.register_filter(:diagnostic_result, diagnostic_filter)
    end

    %i[skip].each do |policy|
      it "preserves a root custom result diagnostic with #{policy} policy" do
        Scry.configuration.invalid_filter_policy = policy

        result = Scry.filter_records_by(
          records: User,
          filter: {type: :diagnostic_result}
        )

        expect(result).to be_failed
        expect(result.relation).to be_empty
        expect(result.diagnostics).to contain_exactly(
          have_attributes(code: :custom_invalid, path: [])
        )
      end
    end

    it 'raises FilterError with a root custom result diagnostic under raise policy' do
      Scry.configuration.invalid_filter_policy = :raise

      expect {
        Scry.filter_records_by(records: User, filter: {type: :diagnostic_result})
      }.to raise_error(Scry::FilterError) { |error|
        expect(error.result).to be_failed
        expect(error.result.diagnostics).to contain_exactly(
          have_attributes(code: :custom_invalid, path: [])
        )
      }
    end

    it 'preserves a nested custom result diagnostic while applying valid siblings' do
      match = create(:user, first_name: 'Custom diagnostic match')

      result = Scry.filter_records_by(
        records: User,
        filter: group(
          property('first_name', 'eq', match.first_name),
          {type: :diagnostic_result}
        )
      )

      expect(result).to be_partial
      expect(result.relation).to contain_exactly(match)
      expect(result.diagnostics).to contain_exactly(
        have_attributes(code: :custom_invalid, path: [:filters, 1])
      )
    end
  end
end
