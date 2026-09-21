require_relative 'support'

RSpec.describe 'Query composition contracts', interoperability: true do
  let!(:organisation) { create(:organisation) }
  let!(:with_email) { create(:user, organisation: organisation, first_name: 'Email owner') }
  let!(:without_email) { create(:user, organisation: organisation, first_name: 'Other owner') }
  let(:scope) { User.where(id: [with_email.id, without_email.id]) }

  before { with_email.emails << create(:email) }

  it 'AF-04 combines a property and aggregate with OR' do
    expect(apply(scope, aggregate('emails', 'gt', 0), property('first_name', 'eq', 'Other owner'), predicate: 'or').ids)
      .to contain_exactly(with_email.id, without_email.id)
  end

  it 'AF-04 combines two aggregates with OR regardless of child order' do
    without_email.phones << create(:phone)
    children = [aggregate('emails', 'gt', 0), aggregate('phones', 'gt', 0)]
    children.permutation.each do |order|
      expect(apply(scope, *order, predicate: 'or').ids).to contain_exactly(with_email.id, without_email.id)
    end
  end

  it 'AF-05 negates aggregate membership inside an existing scope' do
    expect(apply(scope, aggregate('emails', 'gt', 0, negate: true)).ids).to eq([without_email.id])
  end

  it 'AF-05 negates a group containing an aggregate' do
    expect(apply(scope, aggregate('emails', 'gt', 0), negate: true).ids).to eq([without_email.id])
  end

  it 'preserves caller scope through double negation and nested groups' do
    expect(apply(scope, group(aggregate('emails', 'gt', 0), negate: true), negate: true).ids).to eq([with_email.id])
  end

  it 'AF-06 composes aggregates with existing association joins' do
    joined = User.where(id: with_email.id).joins(:organisation)
    expect(apply(joined, aggregate('emails', 'eq', 1)).ids).to eq([with_email.id])
  end

  it 'preserves projections, eager loading, ordering, limits, and offsets' do
    input = scope.select(:id, :first_name, :organisation_id).includes(:organisation).order(:id).limit(1).offset(1)
    result = apply(input, aggregate('emails', 'gteq', 0))
    expect(result.map(&:id)).to eq([without_email.id])
    expect(result.first.association(:organisation)).to be_loaded
    expect(result.first.attributes.keys).to contain_exactly('id', 'first_name', 'organisation_id')
  end

  it 'compiles equivalent filters to stable SQL' do
    expect(apply(scope, aggregate('emails', 'gt', 0)).to_sql).to eq(apply(scope, aggregate('emails', 'gt', 0)).to_sql)
  end

  it 'AF-13 negates the empty AND identity' do
    expect(apply(scope, negate: true)).to be_empty
  end

  it 'AF-13 negates the empty OR identity' do
    expect(apply(scope, predicate: 'or', negate: true).ids).to contain_exactly(with_email.id, without_email.id)
  end
end
