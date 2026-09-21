require_relative 'support'

RSpec.describe 'Policy specificity contracts', interoperability: true do
  [[:matches], :all].each do |grant|
    it "allows a property grant #{grant.inspect} to override global and type exclusions" do
      User.add_filter_permission(:property_predicates) { {first_name: grant} }
      User.add_filter_permission(:type_predicates, list_type: :excludelist) { {textual: [:matches]} }
      User.add_filter_permission(:predicates, list_type: :excludelist) { [:matches] }
      expect(User.filter_predicate_permissions[:first_name]).to include(:matches)
    end

    it "allows a concrete type grant #{grant.inspect} to override an ancestor declared later" do
      User.add_filter_permission(:type_predicates) { {string: grant} }
      User.add_filter_permission(:type_predicates, list_type: :excludelist) { {textual: [:matches]} }
      expect(User.filter_predicate_permissions[:first_name]).to include(:matches)
    end

    it "applies adapter constraints after property grants #{grant.inspect}" do
      Scry.configuration.register_predicate(:sqlite_only_policy, types: [:textual], adapters: [:sqlite], compounds: false, arel_predicate: :eq)
      User.add_filter_permission(:property_predicates) { {first_name: grant == :all ? :all : [:sqlite_only_policy]} }
      expect(User.filter_predicate_permissions[:first_name]).not_to include(:sqlite_only_policy)
    end
  end

  it 'orders concrete and ancestor type entries independently of hash insertion order' do
    User.add_filter_permission(:type_predicates) { {string: [:matches]} }
    User.add_filter_permission(:type_predicates, list_type: :excludelist) { {all: [:matches], textual: [:matches]} }
    expect(User.filter_predicate_permissions[:first_name]).to include(:matches)
  end

  it 'retains registration order between rules of equal specificity' do
    User.add_filter_permission(:type_predicates) { {string: [:matches]} }
    User.add_filter_permission(:type_predicates, list_type: :excludelist) { {string: [:matches]} }
    expect(User.filter_predicate_permissions[:first_name]).not_to include(:matches)
  end

  it 'normalizes property policy keys and predicate names from JSON' do
    User.add_filter_permission(:property_predicates, list_type: :whitelist) { {'first_name' => ['eq']} }
    expect(User.filter_predicate_permissions[:first_name]).to contain_exactly(:eq)
  end

  it 'rejects malformed property policy callback results as filter errors' do
    User.add_filter_permission(:property_predicates) { 123 }
    expect { User.filter_predicate_permissions }.to raise_error(Scry::FilterError, /Hash/)
  end

  it 'uses includelist to grant columns and predicates in strict mode' do
    Scry.configuration.strict = true
    User.add_filter_permission(:properties) { [:first_name] }
    User.add_filter_permission(:property_predicates) { {first_name: [:matches]} }
    expect(User.filter_predicate_permissions[:first_name]).to contain_exactly(:matches)
  end
  it 'normalizes global property permission names from JSON' do
    User.add_filter_permission(:properties, list_type: :whitelist) { ['first_name'] }
    expect(User.filter_property_permissions).to contain_exactly(:first_name)
  end

  it 'rejects malformed global permission results as filter errors' do
    User.add_filter_permission(:properties) { nil }
    expect { User.filter_property_permissions }.to raise_error(Scry::FilterError, /Array or Set/)
  end

end
