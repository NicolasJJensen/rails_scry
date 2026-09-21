# frozen_string_literal: true

require_relative 'support'
require 'stringio'

RSpec.describe 'Review diagnostic and invalid-tree contracts', :interoperability do
  let(:invalid) { property('missing_property', 'eq', 'secret') }

  it 'identifies malformed and unknown children by their complete paths' do
    result = Scry.filter_records_by(records: User, filter: group(123, {type: 'unknown'}))
    expect(result.diagnostics.map(&:path)).to eq([[:filters, 0], [:filters, 1]])
  end

  %w[association aggregate].each do |kind|
    it "preserves outer and scoping paths for #{kind} filters" do
      args = kind == 'association' ? [[1]] : [1]
      node = {type: kind, association: 'users', predicate: kind == 'association' ? 'has_any' : 'gteq', args:,
        scoping: group(invalid)}
      result = Scry.filter_records_by(records: Organisation, filter: group(group(node)))
      expect(result.diagnostics.map(&:path)).to eq([[:filters, 0, :filters, 0, :scoping, :filters, 0]])
    end
  end

  %i[silent warn].each do |mode|
    it "preserves the filter diagnostic if context enrichment raises in #{mode} diagnostic mode" do
      stream = StringIO.new
      Scry.configuration.diagnostic_logging = mode
      Scry.configuration.logger = Logger.new(stream)
      Scry.configuration.log_context = ->(_) { raise 'private-enrichment-error' }
      result = Scry.filter_records_by(records: User, filter: group(invalid))
      expect(result.diagnostics.map(&:category)).to eq([:permission_denied])
      expect(result.diagnostics.map(&:code)).to eq([:property_denied])
      if mode == :warn
        expect(stream.string).to include('permission_denied')
      else
        expect(stream.string).to be_empty
      end
      expect(stream.string).not_to include('private-enrichment-error')
    end
  end

  it 'removes unserializable context while retaining a structured event' do
    stream = StringIO.new
    Scry.configuration.logger = Logger.new(stream)
    Scry.configuration.diagnostic_logging = :warn
    cyclic = []; cyclic << cyclic
    Scry.configuration.log_context = ->(_) { cyclic }
    result = Scry.filter_records_by(records: User, filter: group(invalid))
    expect(result.diagnostics.size).to eq(1)
    expect(stream.string).to include('permission_denied')
  end

  it 'replays cached discovery callback failures with the original log context' do
    stream = StringIO.new
    context = Object.new
    calls = 0
    Scry.clear_thread_caches!
    Scry.configuration.callback_error_policy = :match_none
    Scry.configuration.diagnostic_logging = :warn
    Scry.configuration.logger = Logger.new(stream)
    Scry.configuration.log_context = lambda do |value|
      {context_class: value.class.name, array: value.is_a?(Array)}
    end
    User.add_filter_permission(:properties) { calls += 1; raise 'context callback' }

    2.times { Scry.filter_capabilities(model: User, context:, locale: :fr) }

    events = stream.string.lines.filter_map do |line|
      json = line[line.index('{')..]
      JSON.parse(json) if json&.include?('callback_error')
    end
    expect(calls).to eq(1)
    expect(events.map { |event| event.fetch('context') }).to eq([
      {'context_class' => 'Object', 'array' => false},
      {'context_class' => 'Object', 'array' => false}
    ])
  end

  it 'keeps the configured FilterError when the logger raises' do
    Scry.configuration.invalid_filter_policy = :raise
    Scry.configuration.logger = Object.new.tap do |logger|
      def logger.info(*) = raise('logger-private-error')
    end
    expect { Scry.filter_records_by(records: User, filter: group(invalid)).relation }
      .to raise_error(Scry::FilterError, /invalid property/)
  end

  it 'returns empty error metadata for a non-model object in warn mode' do
    Scry.configuration.diagnostic_logging = :warn
    expect(Scry.filter_capabilities(model: Object.new))
      .to eq(Scry.empty_information.merge(error: true))
  end

  context 'invalid-tree policies' do
    let!(:matching) { create(:user, first_name: 'policy match') }
    let!(:other) { create(:user, first_name: 'other') }
    let(:scope) { User.where(id: [matching.id, other.id]) }

    it 'keeps partial filtering as the default behavior' do
      expect(Scry.configuration.invalid_filter_policy).to eq(:skip)
      expect(apply(scope, property('first_name', 'eq', matching.first_name), invalid).ids).to eq([matching.id])
    end

    it 'rejects an invalid tree even when ordinary errors are ignored' do
      Scry.configuration.invalid_filter_policy = :raise
      expect { apply(scope, property('first_name', 'eq', matching.first_name), invalid) }
        .to raise_error(Scry::FilterError)
    end

    it 'returns no records for an invalid tree, including negated OR groups' do
      Scry.configuration.invalid_filter_policy = :match_none
      result = Scry.filter_records_by(records: scope,
        filter: group(property('first_name', 'eq', matching.first_name), invalid, predicate: 'or', negate: true))
      expect(result.relation.ids).to eq([])
      expect(result.diagnostics.map(&:category)).to eq([:permission_denied])
      expect(result.diagnostics.map(&:code)).to eq([:property_denied])
    end

    it 'treats transform failures as invalid for match-none policy' do
      Scry.configuration.invalid_filter_policy = :match_none
      Scry.configuration.callback_error_policy = :match_none
      User.add_filter_transform(:first_name, on: :value) { raise ArgumentError, 'private-transform-error' }
      expect(apply(scope, property('first_name', 'eq', matching.first_name)).ids).to eq([])
    end

    it 'collects all validation errors independently of the execution policy' do
      Scry.configuration.invalid_filter_policy = :raise
      errors = Scry.validate_filter(model: scope, filter: group(invalid, {type: 'unknown'}))
      expect(errors.size).to eq(2)
      expect(Scry.configuration.invalid_filter_policy).to eq(:raise)
    end

    it 'preserves results for valid filters under match-none policy' do
      Scry.configuration.invalid_filter_policy = :match_none
      expect(apply(scope, property('first_name', 'eq', matching.first_name)).ids).to eq([matching.id])
    end
  end
end
