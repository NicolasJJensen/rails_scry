require_relative 'support'
require 'timeout'

RSpec.describe 'Permission and configuration contracts', interoperability: true do
  it 'AF-02 applies group exclusions to concrete property types and execution' do
    User.add_filter_permission(:type_predicates, list_type: :excludelist) { {textual: [:matches, :starts_with, :ends_with]} }
    expect(User.filter_predicate_permissions[:first_name]).not_to include(:matches, :starts_with, :ends_with)
    Scry.configuration.invalid_filter_policy = :raise
    expect { apply(User, property('first_name', 'matches', 'x')) }.to raise_error(Scry::FilterError)
  end

  it 'AF-15 invalidates permissions after adding a rule' do
    expect(User.filter_property_permissions).to include(:first_name)
    User.add_filter_permission(:properties, list_type: :blacklist) { [:first_name] }
    expect(User.filter_property_permissions).not_to include(:first_name)
  end

  it 'AF-15 invalidates permissions after changing strictness' do
    expect(User.filter_property_permissions).to include(:first_name)
    Scry.configuration.strict = true
    expect(User.filter_property_permissions).to be_empty
  end

  it 'AF-15 invalidates registry lookup caches after changing type membership' do
    cfg = Scry.configuration
    expect(cfg.predicate_registry.by_type(:extension_type)).not_to include(:matches)
    cfg.register_types(:textual, :extension_type)
    expect(cfg.predicate_registry.by_type(:extension_type)).to include(:matches)
  end

  it 'AF-15 invalidates existing caches in other threads' do
    # Mutate the global configuration explicitly. The worker must see the
    # global registry revision even though the example runs in a temporary
    # execution-local configuration overlay.
    cfg = Scry::Configuration.global_instance
    cfg.register_predicate(:cross_thread_contract, types: [:textual], compounds: false, arel_predicate: :eq)
    responses = Queue.new
    proceed = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        responses << User.filter_predicate_permissions[:first_name].include?(:cross_thread_contract)
        proceed.pop
        responses << User.filter_predicate_permissions[:first_name].include?(:cross_thread_contract)
      end
    rescue => error
      responses << error
    end
    expect(Timeout.timeout(5) { responses.pop }).to be true
    cfg.unregister_predicate(:cross_thread_contract)
    proceed << true
    expect(Timeout.timeout(5) { responses.pop }).to be false
  ensure
    proceed << true if proceed
    worker&.join(5)
    worker&.kill if worker&.alive?
    cfg&.unregister_predicate(:cross_thread_contract)
  end

  it 'AF-16 replaces all predicate type memberships on re-registration' do
    cfg = Scry.configuration
    cfg.register_predicate(:replacement_contract, types: [:textual], compounds: false, arel_predicate: :eq)
    cfg.register_predicate(:replacement_contract, types: [:boolean], compounds: false, arel_predicate: :eq)
    expect(cfg.predicate_registry.by_type(:string)).not_to include(:replacement_contract)
    expect(cfg.predicate_registry.by_type(:boolean)).to include(:replacement_contract)
  end

  it 'AF-17 isolates temporary configuration from unrelated threads' do
    global_strict = Scry::Configuration.instance.strict
    Scry.configuration.with_temporary_settings do |temporary|
      temporary.strict = !global_strict
      expect(Thread.new { Scry.configuration.strict }.value).to eq(global_strict)
      expect(Scry.configuration.strict).to eq(!global_strict)
    end
  end

  it 'AF-18 hides capabilities for a denied model' do
    User.add_model_permission { false }
    info = Scry.filter_capabilities(model: User)
    expect(info[:properties]).to be_empty
    expect(info[:associations]).to be_empty
    expect(info[:predicates]).to be_empty
    expect(info[:aggregates]).to be_empty
  end

  it 'redacts permission callback exception details from diagnostics and warnings' do
    secret = 'permission-context-secret'
    context = {token: secret}
    User.add_filter_permission(:properties) do |current_context|
      raise ArgumentError, "unexpected context token: #{current_context[:token]}"
    end
    Scry.configuration.diagnostic_logging = :warn
    Scry.configuration.callback_error_policy = :match_none

    warning_messages = []
    allow(Scry.logger).to receive(:warn) { |message| warning_messages << message }
    result = Scry.filter_records_by(
      records: User,
      filter: group(property('first_name', 'eq', 'Alice')),
      context:
    )

    diagnostics = result.diagnostics.map(&:message)
    expect(diagnostics).to include('Scry: includelist permission callback failed (ArgumentError)')
    expect((warning_messages + diagnostics).join('\n')).not_to include(secret)
  end

  it 'does not let consumers mutate cached enforcement sets' do
    User.add_filter_permission(:properties, list_type: :blacklist) { [:first_name] }
    returned = User.filter_property_permissions
    returned << :first_name unless returned.frozen?
    expect(User.filter_property_permissions).not_to include(:first_name)
  end

  it 'supports typed metadata for custom property filters' do
    definition = {
      type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'active', predicate: 'eq_true' }
      ]
    }
    User.add_custom_property_filter do |_context|
      { vip: { type: :boolean, label: 'VIP customer', predicates: [:eq_true], filter: definition } }
    end

    info = User.filter_capabilities
    property = info[:properties].find { |entry| entry[:key] == 'vip' }
    expect(property).to include(key: 'vip', label: 'VIP customer', type: 'boolean')
    expect(info[:property_predicates][:vip]).to contain_exactly(:eq_true)
    expect(User.custom_property_filters[:vip]).to eq(definition)
  end

  it 'resolves predicate policies through overlapping type groups' do
    cfg = Scry.configuration
    cfg.register_types(:overlap_parent, :overlap_leaf)
    cfg.register_types(:overlap_group, :overlap_parent, :string)
    cfg.register_predicate(:overlap_predicate, types: [:overlap_group], compounds: false, arel_predicate: :eq)

    expect(cfg.predicate_registry.by_type(:overlap_leaf)).to include(:overlap_predicate)
    expect(cfg.predicate_registry.by_type(:string)).to include(:overlap_predicate)
  end
end
