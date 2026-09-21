require_relative 'support'

RSpec.describe 'Association set contracts', interoperability: true do
  let!(:organisation) { create(:organisation) }
  let!(:other_organisation) { create(:organisation) }
  let!(:phone) { create(:phone) }
  let(:scope) { User.where(id: [owner.id, other.id]) }
  let!(:owner) { create(:user, organisation: organisation, phones_count: 0) }
  let!(:other) { create(:user, organisation: other_organisation, phones_count: 0) }

  before { owner.phones << phone }

  it 'requires every distinct requested ID, including missing IDs' do
    missing_id = Phone.maximum(:id) + 1

    expect(apply(scope, association('phones', 'has_all', [phone.id, phone.id.to_s, missing_id])).ids).to be_empty
    expect(apply(scope, association('phones', 'not_has_all', [phone.id, phone.id.to_s, missing_id])).ids)
      .to contain_exactly(owner.id, other.id)
    expect(apply(scope, association('phones', 'only_has_all', [phone.id, phone.id.to_s, missing_id])).ids).to be_empty
  end

  it 'counts requested IDs hidden by the associated model default scope' do
    active = create(:user, organisation: organisation, active: true)
    hidden = create(:user, organisation: organisation, active: false)
    candidates = InteroperabilityModels::ActiveUser.unscoped.where(id: [active.id, hidden.id])
    parent_scope = InteroperabilityModels::Organisation.where(id: [organisation.id, other_organisation.id])

    expect(apply(parent_scope, association('visible_users', 'has_all', [active.id, hidden.id])).ids).to be_empty
    expect(apply(parent_scope, association('visible_users', 'has_all', candidates)).ids).to be_empty
    expect(apply(parent_scope, association('visible_users', 'not_has_all', candidates)).ids)
      .to contain_exactly(organisation.id, other_organisation.id)
    expect(apply(parent_scope, association('visible_users', 'only_has_all', candidates)).ids).to be_empty
  end

  it 'treats an empty scoped relation as vacuous truth without eager queries' do
    sql = []
    listener = lambda do |_name, _start, _finish, _id, payload|
      sql << payload[:sql] unless payload[:name] == 'SCHEMA'
    end

    has_all = nil
    only_has_all = nil
    ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
      has_all = apply(scope, association('phones', 'has_all', Phone.none))
      only_has_all = apply(scope, association('phones', 'only_has_all', Phone.none))
    end

    expect(sql).to be_empty
    expect(has_all.ids).to contain_exactly(owner.id, other.id)
    expect(only_has_all.ids).to contain_exactly(owner.id, other.id)
  end

  it 'applies empty-set identities when an arbitrary candidate scope selects no rows' do
    candidates = Phone.where(id: phone.id, e164: 'impossible number')

    expect(apply(scope, association('phones', 'has_all', candidates)).ids)
      .to contain_exactly(owner.id, other.id)
    expect(apply(scope, association('phones', 'only_has_all', candidates)).ids)
      .to contain_exactly(owner.id, other.id)
    expect(apply(scope, association('phones', 'not_has_all', candidates)).ids).to be_empty
  end

  it 'accepts an Arel select manager as the candidate set' do
    candidates = Phone.where(id: phone.id).select(:id).arel
    query = Scry::AssociationQuery.new(User, :phones)

    expect(scope.where(query.has_all(candidates)).ids).to contain_exactly(owner.id)
    expect(scope.where(query.only_has_all(candidates)).ids).to contain_exactly(owner.id)
  end
end
