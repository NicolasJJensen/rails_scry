require_relative 'support'

RSpec.describe 'Permission discovery consistency', interoperability: true do
  it 'applies accepted predicates to an untyped custom property' do
    User.add_custom_property_filter(predicates: [:eq_true]) { {flag: group(property('active', 'eq_true'))} }
    expect(User.filter_predicate_permissions[:flag]).to contain_exactly(:eq_true)
  end

  it 'refreshes association metadata after the target model policy changes' do
    expect(Organisation.filter_association_permissions).to include(:users)
    User.add_model_permission { false }
    expect(Organisation.filter_association_permissions).not_to include(:users)
  end

  it 'refreshes cached denied associations after the target is granted access' do
    User.add_model_permission { false }
    expect(Organisation.filter_association_permissions).not_to include(:users)
    User.add_model_permission { true }
    expect(Organisation.filter_association_permissions).to include(:users)
  end

  it 'omits disallowed child fields from aggregate discovery' do
    User.add_filter_permission(:properties, list_type: :excludelist) { [:first_name] }
    aggregates = Organisation.scry_permissions.allowed_aggregates(nil)
    expect(aggregates.dig('users', 'min')).not_to include('first_name')
  end

  it 'applies aggregate field constraints after explicit grants' do
    User.add_filter_permission(:properties, list_type: :excludelist) { [:first_name] }
    Organisation.add_filter_permission(:aggregates) { {users: {min: [:first_name], sum: [:first_name]}} }
    aggregates = Organisation.scry_permissions.allowed_aggregates(nil)
    expect(aggregates.dig('users', 'min') || []).not_to include('first_name')
    expect(aggregates.dig('users', 'sum') || []).not_to include('first_name')
  end

  it 'omits unsupported aggregate registrations after explicit grants' do
    Scry.configuration.register_aggregate(:sqlite_only, types: [:textual], adapters: [:sqlite]) { |attr, _| attr.minimum }
    Organisation.add_filter_permission(:aggregates) { {users: {sqlite_only: :all}} }
    expect(Organisation.scry_permissions.allowed_aggregates(nil).fetch('users')).not_to have_key('sqlite_only')
  end
  it 'normalizes custom-property metadata supplied with JSON keys' do
    User.add_custom_property_filter(metadata: {'predicates' => ['eq_true']}) { {flag: group(property('active', 'eq_true'))} }
    expect(User.filter_predicate_permissions[:flag]).to contain_exactly(:eq_true)
  end

  it 'refreshes aggregate metadata when child property permissions change' do
    expect(Organisation.scry_permissions.allowed_aggregates(nil).dig('users', 'min')).to include('first_name')
    User.add_filter_permission(:properties, list_type: :excludelist) { [:first_name] }
    expect(Organisation.scry_permissions.allowed_aggregates(nil).dig('users', 'min')).not_to include('first_name')
  end

  context 'models without Filterable' do
    let(:unsupported_model) do
      stub_const('UnsupportedDiscoveryRecord', Class.new(ActiveRecord::Base))
      UnsupportedDiscoveryRecord.table_name = 'users'
      UnsupportedDiscoveryRecord
    end

    %i[skip match_none].each do |mode|
      it "returns empty error metadata in #{mode} mode" do
        Scry.configuration.invalid_filter_policy = mode
        expect(Scry.filter_capabilities(model: unsupported_model))
          .to eq(Scry.empty_information.merge(error: true))
      end
    end

    it 'returns error metadata for unsupported models under raise mode' do
      Scry.configuration.invalid_filter_policy = :raise
      expect(Scry.filter_capabilities(model: unsupported_model))
        .to eq(Scry.empty_information.merge(error: true))
    end
  end

end
