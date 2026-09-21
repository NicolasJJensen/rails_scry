require_relative 'support'

RSpec.describe 'Association reflection contracts', interoperability: true do
  let!(:organisation) { InteroperabilityModels::Organisation.create!(name: 'Reflection contract') }
  let(:scope) { InteroperabilityModels::Organisation.where(id: organisation.id) }

  it 'AF-03 preserves a declared association scope for membership' do
    inactive = create(:user, organisation: organisation, active: false)
    expect(apply(scope, association('active_users', 'has_any', [inactive.id]))).to be_empty
  end

  it 'AF-03 preserves a declared association scope for zero-inclusive counts' do
    create(:user, organisation: organisation, active: false)
    expect(apply(scope, aggregate('active_users', 'eq', 0)).ids).to eq([organisation.id])
  end

  it 'preserves child default scopes for zero-inclusive counts' do
    create(:user, organisation: organisation, active: false)
    expect(apply(scope, aggregate('visible_users', 'eq', 0)).ids).to eq([organisation.id])
  end

  it 'AF-07 matches self-referential children' do
    child = InteroperabilityModels::Organisation.create!(name: 'Child', parent_id: organisation.id)
    expect(apply(scope, association('children', 'has_any', [child.id])).ids).to eq([organisation.id])
  end

  it 'AF-07 aggregates the resolved child alias' do
    2.times { InteroperabilityModels::Organisation.create!(name: 'Child', parent_id: organisation.id) }
    expect(apply(scope, aggregate('children', 'eq', 2, distinct?: true)).ids).to eq([organisation.id])
  end

  it 'AF-07 supports zero-inclusive self-referential aggregation' do
    expect(apply(scope, aggregate('children', 'eq', 0)).ids).to eq([organisation.id])
  end

  it 'AF-08 honors an association-specific primary key' do
    child = create(:user, organisation: organisation, last_name: organisation.name)
    expect(apply(scope, association('named_users', 'has_any', [child.id])).ids).to eq([organisation.id])
  end

  it 'AF-08 traverses belongs_to followed by has_many' do
    user = InteroperabilityModels::User.create!(organisation: organisation)
    asset = create(:asset, organisation: organisation)
    expect(apply(InteroperabilityModels::User.where(id: user.id), association('organisation_assets', 'has_any', [asset.id])).ids).to eq([user.id])
  end

  it 'AF-09 preserves nested aggregate scoping in the zero-count path' do
    user = create(:user, organisation: organisation)
    user.emails << create(:email)
    scoping = group(aggregate('emails', 'gt', 1))
    expect(apply(scope, aggregate('users', 'eq', 0, scoping: scoping)).ids).to eq([organisation.id])
  end

  it 'AF-09 applies has_one scoping to equivalent zero-count formulations' do
    account = create(:account)
    create(:user, organisation: organisation, account: account, active: false)
    scoping = group(property('active', 'eq_true'))
    %w[eq lt].zip([0, 1]).each do |predicate, value|
      expect(apply(Account.where(id: account.id), aggregate('primary_user', predicate, value, scoping: scoping)).ids).to eq([account.id])
    end
  end
end
