# frozen_string_literal: true

RSpec.shared_examples 'composite key selection contracts' do
  it 'orders and limits a composite-key relation through canonical membership' do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_composite, temporary: connection.adapter_name != 'Mysql2', id: false) do |table|
      table.bigint :tenant_id, null: false
      table.string :code, null: false
      table.integer :amount, null: false
      table.primary_key [:tenant_id, :code]
    end
    stub_const('BoundaryComposite', Class.new(ActiveRecord::Base))
    BoundaryComposite.table_name = 'af_boundary_composite'
    BoundaryComposite.primary_key = %w[tenant_id code]
    BoundaryComposite.include(Scry::Filterable)
    BoundaryComposite.create!(tenant_id: 1, code: 'a', amount: 10)
    BoundaryComposite.create!(tenant_id: 1, code: 'b', amount: 20)

    filter = {
      type: 'group', predicate: 'and', filters: [{type: 'property', property: 'amount', predicate: 'gteq', args: [0]}],
      order: [{property: 'amount', direction: 'desc'}], limit: 1
    }
    expect(Scry.filter_records_by(records: BoundaryComposite, filter:).relation.pluck(:tenant_id, :code))
      .to eq([[1, 'b']])
  ensure
    connection&.drop_table(:af_boundary_composite, if_exists: true)
  end

  it 'counts distinct composite child identities portably' do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_count_owners, id: false) { |table| table.primary_key :id }
    connection.create_table(:af_boundary_count_children, id: false) do |table|
      table.bigint :owner_id, null: false
      table.string :code, null: false
      table.primary_key [:owner_id, :code]
    end
    stub_const('BoundaryCountOwner', Class.new(ActiveRecord::Base))
    stub_const('BoundaryCountChild', Class.new(ActiveRecord::Base))
    BoundaryCountOwner.table_name = 'af_boundary_count_owners'
    BoundaryCountChild.table_name = 'af_boundary_count_children'
    BoundaryCountChild.primary_key = %w[owner_id code]
    BoundaryCountOwner.include(Scry::Filterable)
    BoundaryCountChild.include(Scry::Filterable)
    BoundaryCountOwner.has_many :children, class_name: 'BoundaryCountChild', foreign_key: :owner_id
    owner = BoundaryCountOwner.create!(id: 1)
    BoundaryCountChild.create!(owner_id: owner.id, code: 'a')
    BoundaryCountChild.create!(owner_id: owner.id, code: 'b')

    filter = {
      type: 'group', predicate: 'and', filters: [{
        type: 'aggregate', association: 'children', aggregate: 'count', predicate: 'eq', args: [2],
        'distinct?' => true
      }]
    }
    expect(Scry.filter_records_by(records: BoundaryCountOwner, filter:).relation.ids).to eq([owner.id])
  ensure
    connection&.drop_table(:af_boundary_count_children, if_exists: true)
    connection&.drop_table(:af_boundary_count_owners, if_exists: true)
  end

  it 'matches all composite candidates while only_has_all rejects an outside code' do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_set_owners, id: false) { |table| table.primary_key :id }
    connection.create_table(:af_boundary_set_children, id: false) do |table|
      table.bigint :owner_id, null: false
      table.string :code, null: false
      table.primary_key [:owner_id, :code]
    end
    stub_const('BoundarySetOwner', Class.new(ActiveRecord::Base))
    stub_const('BoundarySetChild', Class.new(ActiveRecord::Base))
    BoundarySetOwner.table_name = 'af_boundary_set_owners'
    BoundarySetChild.table_name = 'af_boundary_set_children'
    BoundarySetChild.primary_key = %w[owner_id code]
    BoundarySetOwner.include(Scry::Filterable)
    BoundarySetChild.include(Scry::Filterable)
    BoundarySetOwner.has_many :children, class_name: 'BoundarySetChild', foreign_key: :owner_id
    owner = BoundarySetOwner.create!(id: 1)
    %w[a b outside].each { |code| BoundarySetChild.create!(owner_id: owner.id, code:) }
    candidates = [[owner.id, 'a'], [owner.id, 'b']]

    %w[has_all only_has_all].each do |predicate|
      filter = {
        type: 'group', predicate: 'and', filters: [{
          type: 'association', association: 'children', predicate:, args: [candidates]
        }]
      }
      expected = predicate == 'has_all' ? [owner.id] : []
      expect(Scry.filter_records_by(records: BoundarySetOwner, filter:).relation.ids).to eq(expected)
    end
  ensure
    connection&.drop_table(:af_boundary_set_children, if_exists: true)
    connection&.drop_table(:af_boundary_set_owners, if_exists: true)
  end

  it 'deduplicates duplicate association join rows before composite has_all counts' do
    connection = ActiveRecord::Base.connection
    %i[af_boundary_join_children af_boundary_join_owners].each do |table|
      connection.drop_table(table, if_exists: true)
    end
    connection.create_table(:af_boundary_join_owners, id: false) { |table| table.primary_key :id }
    connection.create_table(:af_boundary_join_children, id: false) do |table|
      table.bigint :owner_id, null: false
      table.string :code, null: false
      table.primary_key [:owner_id, :code]
    end
    stub_const('BoundaryJoinOwner', Class.new(ActiveRecord::Base))
    stub_const('BoundaryJoinChild', Class.new(ActiveRecord::Base))
    BoundaryJoinOwner.table_name = 'af_boundary_join_owners'
    BoundaryJoinChild.table_name = 'af_boundary_join_children'
    BoundaryJoinChild.primary_key = %w[owner_id code]
    [BoundaryJoinOwner, BoundaryJoinChild].each { |model| model.include(Scry::Filterable) }
    BoundaryJoinOwner.has_many :children,
      -> { joins('CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2 AS n) copies') },
      class_name: 'BoundaryJoinChild', foreign_key: :owner_id
    owner = BoundaryJoinOwner.create!(id: 1)
    %w[a b].each do |code|
      BoundaryJoinChild.create!(owner_id: owner.id, code:)
    end
    expect(owner.children.count).to eq(4)
    candidates = [[owner.id, 'a'], [owner.id, 'b']]
    query = Scry::AssociationQuery.new(BoundaryJoinOwner, :children)
    query.instance_variable_set(:@joined_relation, query.joined_relation.joins('CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2 AS n) copies'))
    raw_count = query.matching(candidates).group(*query.parent_keys).having(Arel.star.count.gteq(3))
    expect(BoundaryJoinOwner.where(query.owner_membership(raw_count)).ids).to eq([owner.id])
    expect(BoundaryJoinOwner.where(query.has_all(candidates)).ids).to eq([owner.id])
    expect(BoundaryJoinOwner.where(query.only_has_all(candidates)).ids).to eq([owner.id])
    expect(BoundaryJoinOwner.where(query.owner_count_at_least(candidates, minimum: 2)).ids).to eq([owner.id])
    expect(BoundaryJoinOwner.where(query.owner_count_at_least(candidates, minimum: 3)).ids).to eq([])
  ensure
    connection&.drop_table(:af_boundary_join_children, if_exists: true)
    connection&.drop_table(:af_boundary_join_owners, if_exists: true)
  end

  it 'rejects incomplete raw Arel projections for composite association keys' do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_arel_owners, id: false) { |table| table.primary_key :id }
    connection.create_table(:af_boundary_arel_children, id: false) do |table|
      table.bigint :owner_id, null: false
      table.string :code, null: false
      table.primary_key [:owner_id, :code]
    end
    stub_const('BoundaryArelOwner', Class.new(ActiveRecord::Base))
    stub_const('BoundaryArelChild', Class.new(ActiveRecord::Base))
    BoundaryArelOwner.table_name = 'af_boundary_arel_owners'
    BoundaryArelChild.table_name = 'af_boundary_arel_children'
    BoundaryArelChild.primary_key = %w[owner_id code]
    BoundaryArelOwner.include(Scry::Filterable)
    BoundaryArelChild.include(Scry::Filterable)
    BoundaryArelOwner.has_many :children, class_name: 'BoundaryArelChild', foreign_key: :owner_id
    BoundaryArelOwner.create!(id: 1)
    BoundaryArelChild.create!(owner_id: 1, code: 'a')
    candidate = BoundaryArelChild.select(:owner_id).arel

    Scry.configuration.with_temporary_settings do |config|
      config.invalid_filter_policy = :raise
      %w[has_any has_all only_has_any only_has_all].each do |predicate|
        filter = {
          type: 'group', predicate: 'and', filters: [{
            type: 'association', association: 'children', predicate:, args: [candidate]
          }]
        }
        expect { Scry.filter_records_by(records: BoundaryArelOwner, filter:).relation }
          .to raise_error(Scry::FilterError, /projection.*primary key/), predicate
      end
    end
  ensure
    connection&.drop_table(:af_boundary_arel_children, if_exists: true)
    connection&.drop_table(:af_boundary_arel_owners, if_exists: true)
  end
end
