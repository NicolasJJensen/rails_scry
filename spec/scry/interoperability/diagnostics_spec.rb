require_relative 'support'
require 'stringio'

RSpec.describe 'Input limits and diagnostics', :interoperability do
  it 'collects nested failures while applying valid siblings' do
    match = create(:user, first_name: 'Diagnostic match')
    create(:user, first_name: 'Other')
    result = Scry.filter_records_by(records: User, filter: group(
      property('first_name', 'eq', match.first_name),
      group(property('missing_property', 'eq', 'secret'))
    ))
    expect(result.relation.ids).to eq([match.id])
    expect(result.diagnostics.map(&:path)).to eq([[:filters, 1, :filters, 0]])
    expect(result.diagnostics.first.category).to eq(:permission_denied)
    expect(result.diagnostics.first.code).to eq(:property_denied)
    expect(result.diagnostics).to be_frozen
  end

  it 'validates without selecting records and restores the configured error mode' do
    Scry.configuration.invalid_filter_policy = :raise
    User.filter_capabilities(nil)
    selects = []
    listener = ->(_name, _start, _finish, _id, payload) { selects << payload[:sql] if payload[:sql].match?(/SELECT.*FROM "users"/i) }
    diagnostics = ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
      Scry.validate_filter(model: User, filter: group(property('missing_property', 'eq', 'secret')))
    end
    expect(diagnostics.map(&:category)).to eq([:permission_denied])
    expect(diagnostics.map(&:code)).to eq([:property_denied])
    expect(selects).to be_empty
    expect(Scry.configuration.invalid_filter_policy).to eq(:raise)
  end

  it 'logs structured errors without caller context, input values, or exception messages' do
    stream = StringIO.new
    Scry.configuration.logger = Logger.new(stream)
    Scry.configuration.diagnostic_logging = :warn
    Scry.configuration.callback_error_policy = :match_none
    Scry.configuration.register_predicate(:broken_value, types: [:string], arel_predicate: :eq,
      formatter: ->(value) { raise ArgumentError, value })
    result = Scry.filter_records_by(records: User, context: {token: 'context-secret'},
      filter: group(property('first_name', 'broken_value', 'input-secret')))
    expect(result.diagnostics.first.message).to match(/formatter callback failed/)
    expect(stream.string).to include('"source":"Scry"', '"path":["filters",0]')
    expect(stream.string).not_to include('context-secret', 'input-secret')
    expect(result.diagnostics.map(&:message).join).not_to include('input-secret', 'context-secret')
  end

  it 'supports explicitly selected context fields in log events' do
    stream = StringIO.new
    Scry.configuration.logger = Logger.new(stream)
    Scry.configuration.diagnostic_logging = :warn
    Scry.configuration.log_context = ->(context) { {request_id: context[:request_id]} }
    Scry.filter_records_by(records: User, context: {request_id: 'request-123', token: 'secret'},
      filter: group(property('missing_property', 'eq', 'value')))
    expect(stream.string).to include('request-123')
    expect(stream.string).not_to include('secret')
  end

  it 'rejects cyclic payloads before recursive normalization' do
    payload = group
    payload[:filters] << payload
    result = Scry.filter_records_by(records: User, filter: payload)
    expect(result.diagnostics.map(&:message).join).to include('cyclic')
    expect(result.relation.to_sql).to eq(User.all.to_sql)
  end

  it 'bounds wide filters before compiling children' do
    Scry.configuration.max_filter_nodes = 20
    result = Scry.filter_records_by(records: User, filter: group(*Array.new(20) { property('first_name', 'eq', 'x') }))
    expect(result.diagnostics.map(&:message).join).to include('max_filter_nodes')
  end

  it 'bounds string payloads including JSON values' do
    Scry.configuration.max_filter_bytes = 100
    result = Scry.filter_records_by(records: User, filter: group(property('jsonb', 'contains', {'secret' => 'x' * 101})))
    expect(result.diagnostics.map(&:message).join).to include('max_filter_bytes')
  end

  it 'raises the configured filter error' do
    Scry.configuration.invalid_filter_policy = :raise
    expect { Scry.filter_records_by(records: User, filter: group(property('missing_property', 'eq', 'x'))) }.to raise_error(Scry::FilterError)
  end
end
