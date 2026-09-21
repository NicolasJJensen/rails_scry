# frozen_string_literal: true

RSpec.shared_examples 'composition contracts' do
  def register_boundary_relation_filter(name, &block)
    implementation = block
    klass = Class.new(Scry::Filters::Base) do
      define_method(:apply) { success(instance_exec(&implementation)) }
    end
    Scry.configuration.register_filter(name, klass)
  end

  it 'preserves a CTE custom relation through AND composition' do
    register_boundary_relation_filter(:cte_boundary_relation) do
      selected = @scope.where(name: 'one').select(:id)
      @scope.with(selected: selected).where("#{@model.table_name}.id IN (SELECT id FROM selected)")
    end

    result = boundary_filter(
      {type: 'cte_boundary_relation'},
      boundary_property('amount', 'lt', 10)
    )

    expect(result.ids).to eq([@first.id])
  end

  it 'preserves a CTE custom relation through OR composition' do
    register_boundary_relation_filter(:cte_boundary_relation) do
      selected = @scope.where(name: 'one').select(:id)
      @scope.with(selected: selected).where("#{@model.table_name}.id IN (SELECT id FROM selected)")
    end

    result = boundary_filter(
      {type: 'cte_boundary_relation'},
      boundary_property('amount', 'gt', 10),
      predicate: 'or'
    )

    expect(result.ids).to contain_exactly(@first.id, @second.id)
  end

  it 'preserves a CTE custom relation through negation' do
    register_boundary_relation_filter(:cte_boundary_relation) do
      selected = @scope.where(name: 'one').select(:id)
      @scope.with(selected: selected).where("#{@model.table_name}.id IN (SELECT id FROM selected)")
    end

    expect(boundary_filter({type: 'cte_boundary_relation'}, negate: true).ids).to eq([@second.id])
  end

  it 'composes a grouped derived-alias custom relation with a paginated candidate relation' do
    register_boundary_relation_filter(:derived_grouped_boundary_relation) do
      source = @scope.select(:id, :name, :amount).arel.as('grouped_boundary_source')
      @scope.from(source).select(source[Arel.star]).group(source[:id], source[:name], source[:amount])
        .having(source[:amount].gt(10))
    end
    candidates = @child.order(name: :desc).limit(1)

    result = boundary_filter(
      {type: 'derived_grouped_boundary_relation'},
      boundary_association('has_all', candidates)
    )

    expect(result.ids).to eq([@second.id])
  end

  it 'OR-composes a grouped derived-alias custom relation with a paginated candidate inside the caller scope' do
    register_boundary_relation_filter(:or_derived_grouped_boundary_relation) do
      source = @scope.select(:id, :name, :amount).arel.as('or_grouped_boundary_source')
      @scope.from(source).select(source[Arel.star]).group(source[:id], source[:name], source[:amount])
        .having(source[:amount].gt(10))
    end
    excluded = @owner.create!(name: 'three', amount: 30)
    records = @owner.where(id: [@first.id, @second.id])
    candidates = @child.order(:name).limit(1)

    result = boundary_filter(
      {type: 'or_derived_grouped_boundary_relation'},
      boundary_association('has_any', candidates),
      records: records,
      predicate: 'or'
    )

    expect(result.ids).to contain_exactly(@first.id, @second.id)
    expect(result.ids).not_to include(excluded.id)
  end

  it 'negates a grouped derived-alias custom relation composed with a paginated candidate inside the caller scope' do
    register_boundary_relation_filter(:negated_derived_grouped_boundary_relation) do
      source = @scope.select(:id, :name, :amount).arel.as('negated_grouped_boundary_source')
      @scope.from(source).select(source[Arel.star]).group(source[:id], source[:name], source[:amount])
        .having(source[:amount].gt(10))
    end
    excluded = @owner.create!(name: 'three', amount: 30)
    records = @owner.where(id: [@first.id, @second.id])
    candidates = @child.order(name: :desc).limit(1)

    result = boundary_filter(
      {type: 'negated_derived_grouped_boundary_relation'},
      boundary_association('has_all', candidates),
      records: records,
      negate: true
    )

    expect(result.ids).to eq([@first.id])
    expect(result.ids).not_to include(excluded.id)
  end

  it 'rejects a custom relation grouped by another table qualified in SQL' do
    register_boundary_relation_filter(:wrong_sql_group_boundary_relation) do
      @scope.joins(:children).group('af_boundary_children.id')
    end

    expect { boundary_filter({type: 'wrong_sql_group_boundary_relation'}) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'rejects a custom relation grouped by another table through Arel' do
    child_table = @child.arel_table
    register_boundary_relation_filter(:wrong_arel_group_boundary_relation) do
      @scope.joins(:children).group(child_table[:id])
    end

    expect { boundary_filter({type: 'wrong_arel_group_boundary_relation'}) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'reports the nested path for a wrong-table grouping without executing its SQL' do
    register_boundary_relation_filter(:diagnostic_wrong_group_boundary_relation) do
      @scope.joins(:children).group(@model.reflect_on_association(:children).klass.arel_table[:id])
    end
    Scry.configuration.invalid_filter_policy = :skip
    filter = boundary_group(
      boundary_property('name', 'eq', 'one'),
      {type: 'diagnostic_wrong_group_boundary_relation'}
    )

    result = Scry.filter_records_by(records: @owner, filter: filter)

    expect(result.diagnostics.map(&:path)).to include([:filters, 1])
    expect(result.relation.ids).to eq([@first.id])
  end

  it 'rejects a wrong-table grouping through the invalid-filter policy before SQL execution' do
    register_boundary_relation_filter(:rejected_wrong_group_boundary_relation) do
      @scope.joins(:children).group(@model.reflect_on_association(:children).klass.arel_table[:id])
    end
    Scry.configuration.invalid_filter_policy = :skip
    Scry.configuration.invalid_filter_policy = :raise

    expect { boundary_filter({type: 'rejected_wrong_group_boundary_relation'}) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'matches no records for a wrong-table grouping through the invalid-filter policy' do
    register_boundary_relation_filter(:match_none_wrong_group_boundary_relation) do
      @scope.joins(:children).group(@model.reflect_on_association(:children).klass.arel_table[:id])
    end
    Scry.configuration.invalid_filter_policy = :skip
    Scry.configuration.invalid_filter_policy = :match_none

    expect(boundary_filter({type: 'match_none_wrong_group_boundary_relation'}).ids).to eq([])
  end

  it 'rejects a valid aggregate candidate grouped by another table primary key' do
    candidates = @child.joins(:owner)
      .select(@child.arel_table[:id].minimum.as('id'))
      .group(@owner.arel_table[:id])

    expect(candidates.load.map(&:id)).to contain_exactly(@a.id, @c.id)

    expect { boundary_filter(boundary_association('has_any', candidates.arel)) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'accepts canonical qualified SQL and Arel grouping keys' do
    register_boundary_relation_filter(:canonical_sql_group_boundary_relation) do
      @scope.group('af_boundary_owners.id')
    end
    register_boundary_relation_filter(:canonical_arel_group_boundary_relation) do
      @scope.group(@model.arel_table[:id])
    end

    expect(boundary_filter({type: 'canonical_sql_group_boundary_relation'}).ids)
      .to contain_exactly(@first.id, @second.id)
    expect(boundary_filter({type: 'canonical_arel_group_boundary_relation'}).ids)
      .to contain_exactly(@first.id, @second.id)
  end

  it 'accepts a derived alias grouping key and a raw canonical candidate key' do
    register_boundary_relation_filter(:alias_group_boundary_relation) do
      source = @scope.select(:id, :name, :amount).arel.as('boundary_group_alias')
      @scope.from(source).select(source[Arel.star]).group(source[:id], source[:name], source[:amount])
    end
    candidates = @child.where(id: @a.id).select(@child.arel_table[:id]).group(@child.arel_table[:id]).arel

    result = boundary_filter(
      {type: 'alias_group_boundary_relation'},
      boundary_association('has_any', candidates)
    )

    expect(result.ids).to eq([@first.id])
  end

  ['ranking', '"ranking"', :hash].each do |ordering|
    it "preserves retained select-alias ordering #{ordering} through candidate pagination" do
      register_boundary_relation_filter(:ranked_relation) do
        @scope.select("#{@model.table_name}.id, MAX(#{@model.table_name}.name) AS ranking")
          .group(@model.arel_table[:id]).order(ordering == :hash ? {ranking: :desc} : Arel.sql("#{ordering} DESC")).limit(1)
      end
      expect(boundary_filter({type: 'ranked_relation'}).ids).to eq([@second.id])
    end
  end

  it 'preserves select-alias ordering at the custom filter path with offset' do
    register_boundary_relation_filter(:ranked_relation) do
      @scope.select(@model.arel_table[:id], @model.arel_table[:name].maximum.as('ranking'))
        .group(@model.arel_table[:id]).order(Arel.sql('ranking').desc).offset(1)
    end
    result = Scry.filter_records_by(records: @owner,
      filter: boundary_group(boundary_group({type: 'ranked_relation'})))
    expect(result.diagnostics).to eq([])
    expect(result.relation.ids).to eq([@first.id])
  end

  it 'supports ordering by an aggregate expression directly' do
    register_boundary_relation_filter(:ranked_expression) do
      table = @model.arel_table
      @scope.select(table[:id], table[:name].maximum.as('ranking'))
        .group(table[:id]).order(table[:name].maximum.desc).limit(1)
    end
    expect(boundary_filter({type: 'ranked_expression'}).ids).to eq([@second.id])
  end

  it 'supports ordering by a field exposed by a derived source' do
    register_boundary_relation_filter(:ranked_derived) do
      table = @model.arel_table
      source = @scope.select(table[:id], table[:name].maximum.as('ranking'))
        .group(table[:id]).arel.as('ranked_source')
      @scope.from(source).select(source[:id]).order(source[:ranking].desc).limit(1)
    end
    expect(boundary_filter({type: 'ranked_derived'}).ids).to eq([@second.id])
  end

  it 'discards alias ordering safely when there is no pagination' do
    register_boundary_relation_filter(:unpaginated_ranking) do
      table = @model.arel_table
      @scope.select(table[:id], table[:name].maximum.as('ranking'))
        .group(table[:id]).order(Arel.sql('ranking DESC'))
    end
    expect(boundary_filter({type: 'unpaginated_ranking'}).ids).to contain_exactly(@first.id, @second.id)
  end

end
