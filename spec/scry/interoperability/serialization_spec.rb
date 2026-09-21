require_relative 'support'
require_relative 'temporary_table_support'

module InteroperabilityModels
  class EnumAsset < ::Asset
    enum :status, { parked: 0, working: 1 }
  end

  class UpcaseType < ActiveRecord::Type::String
    def serialize(value)
      super(value)&.upcase
    end
  end

  class TypedJob < ::Job
    attribute :title, UpcaseType.new
  end
end

RSpec.describe 'Attribute serialization contracts', :interoperability do
  it 'uses enum mapping for comparison operands' do
    record = InteroperabilityModels::EnumAsset.create!(name: 'Enum asset', status: :working, organisation: create(:organisation))
    expect(apply(InteroperabilityModels::EnumAsset, property('status', 'eq', 'working')).ids).to eq([record.id])
    expect(apply(InteroperabilityModels::EnumAsset, property('status', 'eq', 'parked'))).to be_empty
  end

  it 'uses a custom ActiveRecord type serializer' do
    record = InteroperabilityModels::TypedJob.create!(title: 'mixed case')
    expect(apply(InteroperabilityModels::TypedJob, property('title', 'eq', 'mixed case')).ids).to eq([record.id])
  end

  it 'compares whole PostgreSQL arrays using the column serializer' do
    record = Technician.create!(name: 'Array equality', skills: %w[ruby rails])
    scope = Technician.where(id: record.id)
    expect(apply(scope, property('skills', 'eq', %w[ruby rails])).ids).to eq([record.id])
    expect(apply(scope, property('skills', 'eq', %w[ruby]))).to be_empty
    expect(apply(scope, property('skills', 'eq_any', [%w[java], %w[ruby rails]])).ids).to eq([record.id])
  end

  it 'uses a boolean custom property for both true and false predicates' do
    selected = create(:user, first_name: 'Selected')
    other = create(:user, first_name: 'Other')
    User.add_custom_property_filter(type: :boolean) { {selected: group(property('first_name', 'eq', 'Selected'))} }
    scope = User.where(id: [selected.id, other.id])
    expect(apply(scope, property('selected', 'eq_true')).ids).to eq([selected.id])
    expect(apply(scope, property('selected', 'eq_false')).ids).to eq([other.id])
  end
  it 'uses membership predicates for optional associations' do
    account = Account.create!(username: 'Optional account', password: 'x')
    assigned = Email.create!(address: 'assigned@example.test', account: account)
    missing = Email.create!(address: 'missing@example.test', account: nil)
    scope = Email.where(id: [assigned.id, missing.id])
    expect(apply(scope, association('account', 'has_any', [account.id])).ids).to eq([assigned.id])
    expect(apply(scope, association('account', 'not_has_any', [account.id])).ids).to eq([missing.id])
  end

  it 'executes JSON containment and equality on PostgreSQL json columns' do
    with_temporary_table('af_json_serialization', 'id bigint PRIMARY KEY, document json NOT NULL') do |table|
      model = temporary_model('InteroperabilityTemporary::JsonRecord', table)
      model.create!(id: 1, document: {'a' => 1, 'b' => 2})
      expect(apply(model, property('document', 'contains', {'a' => 1})).ids).to eq([1])
      expect(apply(model, property('document', 'eq', {'b' => 2, 'a' => 1})).ids).to eq([1])
      expect(apply(model, property('document', 'contains', {'a' => 9}))).to be_empty
    end
  end

  it 'serializes scalar range containment with the range element type' do
    with_temporary_table('af_range_scalar', 'id bigint PRIMARY KEY, period daterange NOT NULL') do |table|
      model = temporary_model('InteroperabilityTemporary::RangeRecord', table)
      model.create!(id: 1, period: Date.new(2026, 1, 1)..Date.new(2026, 1, 10))
      expect(apply(model, property('period', 'range_contains', Date.new(2026, 1, 5))).ids).to eq([1])
      expect(apply(model, property('period', 'range_contains', Date.new(2026, 2, 5)))).to be_empty
    end
  end

end
