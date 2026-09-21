# frozen_string_literal: true

require 'rails_helper'
require_relative '../interoperability/temporary_table_support'

RSpec.describe 'association filters with a derived caller source', :interoperability do
  def derived_users(computed: false)
    users = User.arel_table
    projection = if computed
      [users[:id], Arel::Nodes::NamedFunction.new('LOWER', [users[:first_name]]).as('first_name')]
    else
      [users[Arel.star]]
    end
    source = users.project(*projection).as('u_src')
    User.unscoped.from(source).select(Arel.star)
  end

  def loaded_ids(records, filter)
    result = Scry.filter_records_by(records:, filter:, context: nil)

    expect(result).to be_success
    result.relation.load.map(&:id).sort
  end

  def association_filter(predicate: 'has_any', value:, **options)
    {type: 'association', association: 'emails', predicate:, args: [value], **options}
  end

  def aggregate_filter(predicate: 'gteq', value:, **options)
    {type: 'aggregate', association: 'emails', aggregate: 'count', predicate:, args: [value], **options}
  end

  it 'uses the caller alias for direct association membership' do
    match = create(:user)
    email = create(:email, users: [match])
    create(:user)
    filter = association_filter(value: [email.id])

    expect(loaded_ids(derived_users, filter)).to eq(loaded_ids(User.unscoped, filter))
  end

  it 'uses the caller alias for a relation-valued association operand' do
    match = create(:user)
    email = create(:email, users: [match])
    create(:user)
    Scry.configuration.with_temporary_settings do |config|
      config.register_predicate(
        :relation_membership, types: [:many_association], applies_to: [:association], compounds: false
      ) { |attribute, value| attribute.has_any(value) }
      filter = association_filter(predicate: 'relation_membership', value: Email.where(id: email.id))

      expect(loaded_ids(derived_users, filter)).to eq(loaded_ids(User.unscoped, filter))
    end
  end

  it 'uses the caller alias for direct aggregate membership' do
    match = create(:user, emails_count: 1)
    create(:user)
    filter = aggregate_filter(value: 1)

    expect(loaded_ids(derived_users, filter)).to eq(loaded_ids(User.unscoped, filter))
  end

  it 'uses the caller alias when the derived source exposes an explicit id projection' do
    match = create(:user)
    email = create(:email, users: [match])
    create(:user)
    filter = association_filter(value: [email.id])

    expect(loaded_ids(derived_users(computed: true), filter)).to eq(loaded_ids(User.unscoped, filter))
  end

  it 'keeps association membership inside a wrapped group on the caller alias' do
    match = create(:user)
    email = create(:email, users: [match])
    create(:user)
    filter = {
      type: 'group', predicate: 'and', filters: [
        association_filter(value: [email.id])
      ]
    }

    expect(loaded_ids(derived_users, filter)).to eq(loaded_ids(User.unscoped, filter))
  end

  it 'keeps negated association membership on the caller alias' do
    match = create(:user)
    email = create(:email, users: [match])
    other = create(:user)
    source = derived_users.from_clause.value
    records = derived_users.where(source[:id].in([match.id, other.id]))
    ordinary = User.unscoped.where(id: [match.id, other.id])
    filter = association_filter(predicate: 'not_has_any', value: [email.id])

    expect(loaded_ids(records, filter)).to eq(loaded_ids(ordinary, filter))
    expect(loaded_ids(records, filter)).to eq([other.id])
  end

  it 'keeps aggregate membership on a scoped derived relation' do
    match = create(:user, emails_count: 1)
    excluded = create(:user, emails_count: 1)
    source = derived_users.from_clause.value
    records = derived_users.where(source[:id].eq(match.id))
    ordinary = User.unscoped.where(id: match.id)
    filter = aggregate_filter(value: 1)

    expect(loaded_ids(records, filter)).to eq(loaded_ids(ordinary, filter))
    expect(loaded_ids(records, filter)).to eq([match.id])
    expect(excluded).to be_persisted
  end

  it 'uses every composite parent key from the derived caller source' do
    with_temporary_table(
      'af_derived_composite_parents',
      'tenant_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (tenant_id, code)'
    ) do |parents|
      with_temporary_table(
        'af_derived_composite_children',
        'id bigint PRIMARY KEY, tenant_id bigint NOT NULL, code varchar NOT NULL'
      ) do |children|
        owner = temporary_model('AssociationDerivedSource::CompositeOwner', parents)
        child = temporary_model('AssociationDerivedSource::CompositeChild', children)
        owner.primary_key = %w[tenant_id code]
        owner.query_constraints :tenant_id, :code
        child.query_constraints :tenant_id, :code
        owner.has_many :children, class_name: child.name, foreign_key: %i[tenant_id code]
        owner.create!(tenant_id: 1, code: 'A')
        owner.create!(tenant_id: 2, code: 'A')
        child.create!(id: 1, tenant_id: 1, code: 'A')
        child.create!(id: 2, tenant_id: 2, code: 'A')
        table = owner.arel_table
        source = table.project(table[:tenant_id], table[:code]).as('owner_source')
        records = owner.unscoped.from(source).select(Arel.star)
        filter = {type: 'association', association: 'children', predicate: 'has_any', args: [[1]]}

        result = Scry.filter_records_by(records:, filter:, context: nil)

        expect(result).to be_success
        expect(result.relation.load.map { |record| [record.tenant_id, record.code] }).to eq([[1, 'A']])
      end
    end
  end
end
