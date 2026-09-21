require_relative 'support'

RSpec.describe 'Named policy inheritance contracts', interoperability: true do
  before do
    stub_const('PolicyContractParent', Class.new(User))
    stub_const('PolicyContractChild', Class.new(PolicyContractParent))
  end

  it 'dispatches an inherited named model permission on the evaluated subclass' do
    PolicyContractParent.define_singleton_method(:filter_allowed) { |_| true }
    PolicyContractParent.add_model_permission :filter_allowed
    stub_const('PolicyContractChild', Class.new(PolicyContractParent))
    PolicyContractChild.define_singleton_method(:filter_allowed) { |_| false }
    expect(PolicyContractChild.model_allowed?).to be false
    expect(PolicyContractParent.model_allowed?).to be true
  end

  it 'dispatches inherited custom-property methods on the evaluated subclass' do
    PolicyContractParent.define_singleton_method(:virtual_filters) { |_| {parent_flag: {type: :group, predicate: :and, filters: []}} }
    PolicyContractParent.add_custom_property_filter :virtual_filters
    stub_const('PolicyContractChild', Class.new(PolicyContractParent))
    PolicyContractChild.define_singleton_method(:virtual_filters) { |_| {child_flag: {type: :group, predicate: :and, filters: []}} }
    expect(PolicyContractChild.custom_property_filters.keys).to contain_exactly(:child_flag)
  end

  it 'dispatches inherited named transforms on the evaluated subclass' do
    PolicyContractParent.define_singleton_method(:normalize_filter_value) { |value, _| "parent-#{value}" }
    PolicyContractParent.add_filter_transform :first_name, :normalize_filter_value, on: :value
    stub_const('PolicyContractChild', Class.new(PolicyContractParent))
    PolicyContractChild.define_singleton_method(:normalize_filter_value) { |value, _| "child-#{value}" }
    expect(apply(PolicyContractChild, property('first_name', 'eq', 'test')).to_sql).to include('child-test')
  end
end
