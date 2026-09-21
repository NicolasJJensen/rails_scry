# frozen_string_literal: true

require_relative 'candidate_projection_contracts'
require_relative 'review_query_contracts'
require_relative 'association_operand_contracts'
require_relative 'composition_contracts'
require_relative 'discovery_contracts'
require_relative 'computed_selection_contracts'
require_relative 'composite_key_selection_contracts'
require_relative 'association_selection_adapter_contracts'
require_relative 'association_ranking_contracts'
require_relative 'custom_condition_contracts'

RSpec.shared_examples 'interoperability boundaries' do
  include_examples 'candidate projection contracts'
  include_examples 'review query contracts'
  include_examples 'association operand contracts'
  include_examples 'composition contracts'
  include_examples 'discovery contracts'
  include_examples 'computed selection contracts'
  include_examples 'composite key selection contracts'
  include_examples 'association selection adapter contracts'
  include_examples 'association ranking contracts'
  include_examples 'custom condition contracts'
  def boundary_group(*children, **options)
    {type: 'group', predicate: 'and', filters: children, **options}
  end

  def boundary_property(name, predicate, *args)
    {type: 'property', property: name, predicate: predicate, args: args}
  end

  def boundary_association(predicate, *args)
    {type: 'association', association: 'children', predicate: predicate, args: args}
  end

  def boundary_filter(*children, records: @owner, **options)
    Scry.filter_records_by(records: records, filter: boundary_group(*children, **options)).relation
  end

  around do |example|
    Scry.configuration.with_temporary_settings do |settings|
      settings.invalid_filter_policy = :raise
      settings.callback_error_policy = :raise
      example.run
    end
  end

  before do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_owners, temporary: connection.adapter_name != 'Mysql2') do |table|
      table.string :name
      table.integer :amount
      table.integer :tenant_id
      table.datetime :deleted_at
    end
    connection.create_table(:af_boundary_children, temporary: connection.adapter_name != 'Mysql2') do |table|
      table.integer :owner_id
      table.string :name
      table.integer :status
      table.integer :amount
    end
    stub_const('BoundaryOwner', Class.new(ActiveRecord::Base))
    stub_const('BoundaryChild', Class.new(ActiveRecord::Base))
    @owner = BoundaryOwner
    @child = BoundaryChild
    @owner.table_name = 'af_boundary_owners'
    @child.table_name = 'af_boundary_children'
    [@owner, @child].each { |model| model.include(Scry::Filterable) }
    @owner.has_many :children, class_name: 'BoundaryChild', foreign_key: :owner_id
    @child.belongs_to :owner, class_name: 'BoundaryOwner', foreign_key: :owner_id
    @first = @owner.create!(name: 'one', amount: 5)
    @second = @owner.create!(name: 'two', amount: 20)
    @a = @child.create!(owner_id: @first.id, name: 'a', amount: 5, status: 1)
    @b = @child.create!(owner_id: @first.id, name: 'b', amount: 20, status: 1)
    @c = @child.create!(owner_id: @second.id, name: 'c', amount: 30, status: 0)
  end

  after do
    %i[af_boundary_children af_boundary_owners].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    rescue ActiveRecord::StatementInvalid
      # PostgreSQL rolls back temporary tables after a failed fixture transaction.
    end
    Scry.clear_thread_caches!
  end

  [nil, 'bad'].each do |invalid|
    it "rejects invalid candidate ID #{invalid.inspect} before an exclusive comparison" do
      expect { boundary_filter(boundary_association('only_has_any', [@a.id, invalid])) }
        .to raise_error(Scry::FilterError, /ID/)
    end
  end

  it 'retains nonexistent valid IDs when counting the requested set' do
    expect(boundary_filter(boundary_association('has_all', [@a.id, 999_999_999])).ids).to eq([])
  end

  %w[between not_between].each do |predicate|
    it "normalizes numeric strings before #{predicate} ordering" do
      expected = predicate == 'between' ? [@first.id] : [@second.id]
      expect(boundary_filter(boundary_property('amount', predicate, '2', '10')).ids).to eq(expected)
    end
  end

  it 'normalizes aggregate range endpoints before ordering' do
    node = {type: 'aggregate', association: 'children', aggregate: 'min', property: 'amount', predicate: 'between', args: ['2', '10']}
    expect(boundary_filter(node).ids).to eq([@first.id])
  end

  it 'aggregates a field from the selected row of a per-owner limited association' do
    @owner.has_many :latest_children, -> { order(id: :desc).limit(1) }, class_name: 'BoundaryChild', foreign_key: :owner_id
    node = {type: 'aggregate', association: 'latest_children', aggregate: 'sum', property: 'amount', predicate: 'eq', args: [20]}
    expect(boundary_filter(node).ids).to eq([@first.id])
  end

  it 'preserves a candidate page ordered by a non-key column' do
    candidates = @child.order(name: :desc).limit(1)
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@second.id])
  end

  it 'deduplicates after pagination rather than changing the page' do
    candidates = @child.joins('CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2 AS n) copies').order(:id).limit(2)
    expect(candidates.ids).to eq([@a.id, @a.id])
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@first.id])
  end

  it 'uses an attribute override when discovering its type' do
    @owner.attribute :amount, :boolean
    info = Scry.filter_capabilities(model: @owner)
    expect(info[:properties].find { |item| item[:key] == 'amount' }[:type]).to eq('boolean')
    expect(info[:property_predicates][:amount]).to include(:eq_true)
  end

  it 'executes a predicate registered for a custom logical type' do
    currency = Class.new(ActiveRecord::Type::Integer) { def type = :currency }.new
    @owner.attribute :amount, currency
    Scry.configuration.register_types(:currency)
    Scry.configuration.register_predicate(:costs_more, types: [:currency], compounds: false) do |attr, value|
      attr.gt(value)
    end
    expect(boundary_filter(boundary_property('amount', 'costs_more', 10)).ids).to eq([@second.id])
  end

  ['active', 1].each do |value|
    it "serializes enum aggregate operand #{value.inspect}" do
      @child.enum :status, {draft: 0, active: 1}
      node = {type: 'aggregate', association: 'children', aggregate: 'min', property: 'status', predicate: 'eq', args: [value]}
      expect(boundary_filter(node).ids).to eq([@first.id])
    end
  end

  it 'filters values exposed by an aliased derived relation' do
    source = @owner.select(:id, Arel.sql('name'), Arel.sql('amount + 100 AS amount')).arel.as('boundary_source')
    records = @owner.from(source).select(source[Arel.star])
    expect(boundary_filter(boundary_property('amount', 'eq', 105), records: records).map(&:id)).to eq([@first.id])
    expect(boundary_filter(boundary_property('amount', 'eq', 5), records: records).map(&:id)).to eq([])
  end

  %i[ignore warn raise].each do |mode|
    it "handles an invalid scalar operand before SQL construction in #{mode} mode" do
      settings = Scry.configuration
      settings.invalid_filter_policy = mode == :raise ? :raise : :skip
      settings.diagnostic_logging = mode == :warn ? :warn : :silent
      node = boundary_property('name', 'matches', ['one', 'two'])
      if mode == :raise
        expect { boundary_filter(node) }.to raise_error(Scry::FilterError, /operand|value/)
      else
        result = Scry.filter_records_by(records: @owner, filter: boundary_group(node))
        expect(result.diagnostics).not_to be_empty
        expect { result.relation.load }.not_to raise_error
      end
    end
  end

  it 'preserves programming errors from discovery callbacks' do
    Scry.configuration.invalid_filter_policy = :skip
    @owner.add_filter_permission(:properties) { missing_boundary_policy_method }
    expect { Scry.filter_capabilities(model: @owner) }.to raise_error(NameError, /missing_boundary_policy_method/)
  end

  it 'restores immutable canonical registry entries' do
    registry = Scry.configuration.predicate_registry
    registry.restore(registry.snapshot)
    expect(registry.by_name(:eq)).to be_frozen
    expect(registry.by_name(:eq)[:types]).to be_frozen
    expect { registry.by_name(:eq)[:types] << :other }.to raise_error(FrozenError)
  end

  it 'keeps temporary configuration entries immutable' do
    Scry.configuration.with_temporary_settings do |settings|
      expect(settings.predicate_registry.by_name(:eq)[:types]).to be_frozen
    end
  end

  it 'invalidates permissions when the model switches tables' do
    expect(@owner.filter_property_permissions).to include(:name)
    @owner.table_name = 'af_boundary_children'
    @owner.reset_column_information
    expect(@owner.filter_property_permissions).to include(:status)
  end

  it 'invalidates discovery after schema information is reset' do
    @owner.filter_property_permissions
    ActiveRecord::Base.connection.add_column(:af_boundary_owners, :label, :string)
    @owner.reset_column_information
    expect(@owner.filter_property_permissions).to include(:label)
  end
  it 'rejects invalid filter classes during registration' do
    expect { Scry.configuration.register_filter(:broken, Object) }.to raise_error(ArgumentError)
  end

  it 'rejects incompatible filter constructors during registration' do
    klass = Class.new(Scry::Filters::Base) { def initialize(required_positional); end }
    expect { Scry.configuration.register_filter(:broken, klass) }.to raise_error(ArgumentError)
  end

  it 'rejects invalid predicate callbacks and type metadata during registration' do
    config = Scry.configuration
    expect { config.register_predicate(:broken, formatter: Object.new, arel_predicate: :eq) }.to raise_error(ArgumentError)
    expect { config.register_predicate(:broken, arel_predicate: :eq) }.not_to raise_error
    expect { config.register_predicate(:broken, types: [], arel_predicate: :eq) }.to raise_error(ArgumentError)
  end

  it 'rejects aggregate registration without an executable builder' do
    expect { Scry.configuration.register_aggregate(:broken) }.to raise_error(ArgumentError)
  end

  it 'supports a strict one-argument zero-operand predicate callback' do
    Scry.configuration.register_predicate(:named_one, types: [:textual], compounds: false, &->(attribute) { attribute.eq('one') })
    expect(boundary_filter(boundary_property('name', 'named_one')).ids).to eq([@first.id])
  end

  it 'accepts a strict one-argument zero-operand predicate callback' do
    Scry.configuration.register_predicate(:broken, types: [:textual], compounds: false, &->(attribute) { attribute.eq('one') })
    expect(boundary_filter(boundary_property('name', 'broken')).ids).to eq([@first.id])
  end

  it 'bounds invalid identifiers in diagnostics and logs' do
    require 'stringio'
    output = StringIO.new
    Scry.configuration.logger = Logger.new(output)
    Scry.configuration.invalid_filter_policy = :skip
    result = Scry.filter_records_by(records: @owner,
      filter: boundary_group(boundary_property('x' * 4000, 'eq', 'secret-value')))
    expect(result.diagnostics.map(&:message).join.bytesize).to be < 1024
    expect(output.string.bytesize).to be < 2048
    expect(output.string).not_to include('secret-value')
  end

  it 'composes derived properties with association membership and negation' do
    source = @owner.select(:id, Arel.sql('UPPER(name) AS name'), :amount).arel.as('boundary_source')
    records = @owner.from(source).select(source[Arel.star]).order(source[:id]).limit(1)
    expect(boundary_filter(boundary_property('name', 'eq', 'ONE'), boundary_association('has_any', [@a.id]),
      records: records).map(&:id)).to eq([@first.id])
    expect(boundary_filter(boundary_property('name', 'eq', 'ONE'), records: records, negate: true).map(&:id)).to eq([@second.id])
    expect(boundary_filter(boundary_property('name', 'eq', 'ONE').merge(negate: true), records: records).map(&:id)).to eq([@second.id])
  end

  it 'preserves an explicitly distinct candidate relation with non-key ordering' do
    candidates = @child.order(name: :desc).distinct.limit(1)
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@second.id])
  end

  it 'preserves a Pundit policy scope together with soft deletion, OR, negation, and pagination' do
    require 'pundit'
    @first.update!(tenant_id: 1)
    @second.update!(tenant_id: 2)
    visible_empty = @owner.create!(name: 'empty', tenant_id: 1)
    @owner.create!(name: 'deleted', tenant_id: 1, deleted_at: Time.current)
    @owner.send(:default_scope, -> { where(deleted_at: nil) })
    policy = Class.new
    policy.const_set(:Scope, Class.new do
      def initialize(user, scope)
        @user, @scope = user, scope
      end
      def resolve
        @scope.where(tenant_id: @user)
      end
    end)
    stub_const('BoundaryOwnerPolicy', policy)
    scope = Pundit.policy_scope!(1, @owner).order(:id).limit(1)
    count = {type: 'aggregate', association: 'children', aggregate: 'count', predicate: 'gt', args: [0]}
    expect(boundary_filter(count, boundary_property('name', 'eq', 'two'), records: scope, predicate: 'or').ids).to eq([@first.id])
    expect(boundary_filter(count, records: scope, negate: true).ids).to eq([visible_empty.id])
  end

  it 'uses a custom serializer for property-result aggregates' do
    type = Class.new(ActiveRecord::Type::String) { def serialize(value) = value&.upcase }.new
    @child.attribute :name, type
    @child.where(id: [@a.id, @b.id]).update_all(name: 'match')
    node = {type: 'aggregate', association: 'children', aggregate: 'min', property: 'name', predicate: 'eq', args: ['match']}
    expect(boundary_filter(node).ids).to eq([@first.id])
  end

  it 'preserves complete structured values and compound alternatives for serializers' do
    @owner.serialize :name, coder: JSON
    record = @owner.create!(name: ['ruby', {'framework' => 'rails'}])
    operand = ['ruby', {'framework' => 'rails'}]
    expect(boundary_filter(boundary_property('name', 'eq', operand)).ids).to eq([record.id])
    expect(boundary_filter(boundary_property('name', 'eq_any', [operand, []])).ids).to eq([record.id])
  end

  it 'filters time ranges in standalone applications without a time zone' do
    previous = Time.zone
    Time.zone = nil
    @first.update!(deleted_at: Time.current - 3600)
    expect(boundary_filter(boundary_property('deleted_at', 'within_previous', 'P1D')).ids).to eq([@first.id])
  ensure
    Time.zone = previous
  end

  it 'invalidates parent aggregate discovery after child logical type changes' do
    before = @owner.scry_permissions.allowed_aggregates(nil)
    @child.attribute :amount, :string
    after = @owner.scry_permissions.allowed_aggregates(nil)
    Scry.clear_thread_caches!
    expect(after).to eq(@owner.scry_permissions.allowed_aggregates(nil))
    expect(after).not_to eq(before)
  end

  it 'rejects required keyword arguments on ordinary callback blocks' do
    expect do
      Scry.configuration.register_predicate(:needs_key, compounds: false) { |attr, value, required:| attr.eq(value) }
    end.to raise_error(ArgumentError)
  end

  it 'rejects abstract filter extensions' do
    expect { Scry.configuration.register_filter(:abstract, Class.new(Scry::Filters::Base)) }.to raise_error(ArgumentError)
  end

  it 'serializes range endpoints for derived sources' do
    type = Class.new(ActiveRecord::Type::Integer) do
      def serialize(value) = value.nil? ? nil : super(value) + 100
      def deserialize(value) = value.nil? ? nil : super(value) - 100
    end.new
    @owner.attribute :amount, type
    @owner.where(id: @first.id).update_all(amount: 5)
    source = @owner.select(:id, :amount).arel.as('boundary_source')
    records = @owner.from(source).select(source[Arel.star])
    expect(boundary_filter(boundary_property('amount', 'between', 1, 10), records: records).map(&:id)).to eq([@first.id])
  end

  it 'serializes range endpoints once for an ordinary table alias' do
    type = Class.new(ActiveRecord::Type::Integer) do
      def serialize(value) = value.nil? ? nil : super(value) + 100
      def deserialize(value) = value.nil? ? nil : super(value) - 100
    end.new
    @owner.attribute :amount, type
    @owner.where(id: @first.id).update_all(amount: 5)
    alias_table = @owner.arel_table.alias('ordinary_owner')
    condition = Scry::Compatibility.range_condition(alias_table[:amount], 1, 10)

    # Real-table aliases already type-cast through Arel; only derived aliases lack that caster.
    records = @owner.from(alias_table).select(alias_table[Arel.star])
    expect(records.where(condition).map(&:id)).to eq([@first.id])
  end

  it 'preserves eager-loading joins in distinct candidate relations' do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_categories, temporary: connection.adapter_name != 'Mysql2') { |table| table.string :name }
    stub_const('BoundaryCategory', Class.new(ActiveRecord::Base))
    BoundaryCategory.table_name = 'af_boundary_categories'
    category = BoundaryCategory.create!(name: 'wanted')
    @child.belongs_to :category, class_name: 'BoundaryCategory', foreign_key: :status
    @child.where(id: [@a.id, @b.id]).update_all(status: category.id)
    candidates = @child.eager_load(:category).distinct.where(af_boundary_categories: {name: 'wanted'})
    expect(boundary_filter(boundary_association('has_any', candidates)).ids).to eq([@first.id])
  ensure
    connection.drop_table(:af_boundary_categories, if_exists: true)
  end

end
