# frozen_string_literal: true

require 'bigdecimal'
require 'set'

RSpec.shared_examples 'review query contracts' do
  def boundary_aggregate(predicate, *args)
    {type: 'aggregate', association: 'children', aggregate: 'count', predicate: predicate, args: args}
  end

  [nil, 'not-an-id'].each do |value|
    it "rejects scalar association ID #{value.inspect} like its array form" do
      expect { boundary_filter(boundary_association('has_any', value)) }
        .to raise_error(Scry::FilterError, /ID/)
      expect { boundary_filter(boundary_association('has_any', [value])) }
        .to raise_error(Scry::FilterError, /ID/)
    end
  end

  it 'accepts a scalar association ID like its array form' do
    scalar = boundary_filter(boundary_association('has_any', @a.id)).ids
    array = boundary_filter(boundary_association('has_any', [@a.id])).ids

    expect(scalar).to eq(array).and eq([@first.id])
  end

  %w[has_all only_has_all].each do |predicate|
    it "retains a nonexistent scalar ID in the requested count for #{predicate}" do
      scalar = boundary_filter(boundary_association(predicate, 999_999_999)).ids
      array = boundary_filter(boundary_association(predicate, [999_999_999])).ids

      expect(scalar).to eq(array).and eq([])
    end

    it "rejects an invalid scalar ID for #{predicate}" do
      expect { boundary_filter(boundary_association(predicate, 'not-an-id')) }
        .to raise_error(Scry::FilterError, /ID/)
    end
  end

  it 'accepts a set of association IDs like its array form' do
    set = boundary_filter(boundary_association('has_all', Set[@a.id, @b.id])).ids
    array = boundary_filter(boundary_association('has_all', [@a.id, @b.id])).ids

    expect(set).to eq(array).and eq([@first.id])
  end

  it 'normalizes a scalar association ID using a custom primary key' do
    @child.primary_key = 'name'

    scalar = boundary_filter(boundary_association('has_any', 'a')).ids
    array = boundary_filter(boundary_association('has_any', ['a'])).ids
    expect(scalar).to eq(array).and eq([@first.id])
  end

  [1.5, BigDecimal('1.5'), '1.5'].each do |value|
    it "rejects fractional integer aggregate operand #{value.inspect}" do
      expect { boundary_filter(boundary_aggregate('eq', value)) }
        .to raise_error(Scry::FilterError, /invalid aggregate operand/)
    end
  end

  [
    [1.5, 2],
    [BigDecimal('1.5'), BigDecimal('2')],
    ['1.5', '2']
  ].each do |value|
    it "rejects fractional integer aggregate range #{value.inspect}" do
      expect { boundary_filter(boundary_aggregate('between', *value)) }
        .to raise_error(Scry::FilterError, /invalid aggregate operand/)
    end
  end

  it 'rejects a derived source that does not expose the model primary key' do
    source = @owner.select(:name, :amount).arel.as('boundary_source')
    records = @owner.from(source).select(source[Arel.star])

    expect { boundary_filter(boundary_property('name', 'eq', 'one'), records: records) }
      .to raise_error(Scry::FilterError, /source.*primary key|primary key.*source/)
  end

  it 'accepts a derived source that exposes the model primary key under its canonical name' do
    source = @owner.select(:id, :name, :amount).arel.as('boundary_source')
    records = @owner.from(source).select(source[Arel.star])

    expect(boundary_filter(boundary_property('name', 'eq', 'one'), records: records).ids).to eq([@first.id])
  end

  it 'accepts a derived source with its primary key explicitly aliased to its canonical name' do
    source = @owner.select(@owner.arel_table[:id].as('id'), :name, :amount).arel.as('boundary_source')
    records = @owner.from(source).select(source[Arel.star])

    expect(boundary_filter(boundary_property('name', 'eq', 'one'), records: records).ids).to eq([@first.id])
  end

  it 'rejects a nested derived wildcard when the inner source omits the primary key' do
    inner = @owner.select(:name, :amount).arel.as('inner_boundary_source')
    outer = @owner.from(inner).select(inner[Arel.star]).arel.as('outer_boundary_source')
    records = @owner.from(outer).select(outer[Arel.star])

    expect { boundary_filter(boundary_property('name', 'eq', 'one'), records: records) }
      .to raise_error(Scry::FilterError, /source.*primary key|primary key.*source/)
  end

  it 'accepts a nested derived wildcard when the inner source exposes the primary key' do
    inner = @owner.select(:id, :name, :amount).arel.as('inner_boundary_source')
    outer = @owner.from(inner).select(inner[Arel.star]).arel.as('outer_boundary_source')
    records = @owner.from(outer).select(outer[Arel.star])

    expect(boundary_filter(boundary_property('name', 'eq', 'one'), records: records).ids).to eq([@first.id])
  end

  it 'rejects an explicit nested key attribute when the inner source omits the primary key' do
    inner = @owner.select(:name, :amount).arel.as('inner_boundary_source')
    outer = @owner.from(inner).select(inner[:id], inner[:name]).arel.as('outer_boundary_source')
    records = @owner.from(outer).select(outer[Arel.star])

    expect { boundary_filter(boundary_property('name', 'eq', 'one'), records: records) }
      .to raise_error(Scry::FilterError, /source.*primary key|primary key.*source/)
  end

  it 'accepts a qualified SQL wildcard from a valid nested derived alias' do
    inner = @owner.select(:id, :name, :amount).arel.as('inner_boundary_source')
    outer = @owner.from(inner).select('inner_boundary_source.*').arel.as('outer_boundary_source')
    records = @owner.from(outer).select(outer[Arel.star])

    expect(boundary_filter(boundary_property('name', 'eq', 'one'), records: records).ids).to eq([@first.id])
  end

  it 'rejects a grouped candidate relation that does not group by its primary key' do
    candidates = @child.select(:id).group(:name)

    expect { boundary_filter(boundary_association('has_any', candidates)) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'accepts a grouped candidate relation grouped by its primary key' do
    candidates = @child.where(id: @a.id).select(:id).group(:id)

    expect(boundary_filter(boundary_association('has_any', candidates)).ids).to eq([@first.id])
  end

  it 'rejects a distinct grouped candidate that bypasses ordinary projection' do
    candidates = @child.select(:id).group(:name).distinct

    expect { boundary_filter(boundary_association('has_any', candidates)) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'rejects a raw grouped candidate that bypasses ordinary projection' do
    candidates = @child.select(:id).group(:name).arel

    expect { boundary_filter(boundary_association('has_any', candidates)) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'rejects a distinct candidate whose derived source omits the primary key' do
    source = @child.select(:name).arel.as('boundary_child_source')
    candidates = @child.from(source).select(source[:id]).distinct

    expect { boundary_filter(boundary_association('has_any', candidates)) }
      .to raise_error(Scry::FilterError, /source.*primary key|primary key.*source/)
  end

  it 'rejects a raw candidate whose derived source omits the primary key' do
    source = @child.select(:name).arel.as('boundary_child_source')
    candidates = @child.from(source).select(source[:id]).arel

    expect { boundary_filter(boundary_association('has_any', candidates)) }
      .to raise_error(Scry::FilterError, /source.*primary key|primary key.*source/)
  end

  it 'rejects a grouped custom-filter relation that does not group by its primary key' do
    grouped_filter = Class.new(Scry::Filters::Base) do
      def apply = success(@scope.group(:name))
    end
    Scry.configuration.register_filter(:grouped_review_relation, grouped_filter)

    expect { boundary_filter({type: 'grouped_review_relation'}) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'rejects a grouped custom-filter relation with raw non-key grouping' do
    grouped_filter = Class.new(Scry::Filters::Base) do
      def apply = success(@scope.select(Arel.sql('id')).group(Arel.sql('name')))
    end
    Scry.configuration.register_filter(:raw_grouped_review_relation, grouped_filter)

    expect { boundary_filter({type: 'raw_grouped_review_relation'}) }
      .to raise_error(Scry::FilterError, /group.*primary key|primary key.*group/)
  end

  it 'accepts a grouped custom-filter relation with raw primary-key grouping' do
    grouped_filter = Class.new(Scry::Filters::Base) do
      def apply = success(@scope.select(Arel.sql('id')).group(Arel.sql('af_boundary_owners.id')))
    end
    Scry.configuration.register_filter(:raw_key_grouped_review_relation, grouped_filter)

    expect(boundary_filter({type: 'raw_key_grouped_review_relation'}).ids).to contain_exactly(@first.id, @second.id)
  end

  it 'preserves a grouped root relation when no membership projection is required' do
    records = @owner.group(:id)

    expect(boundary_filter(boundary_property('name', 'eq', 'one'), records: records).ids).to eq([@first.id])
  end

  it 'contains a root custom relation within the caller scope' do
    custom_filter = Class.new(Scry::Filters::Group) do
      def apply
        success(@model.unscoped.where(id: @filter.fetch(:id)))
      end
    end
    Scry.configuration.register_filter(:root_scope_boundary_review, custom_filter)

    result = Scry.filter_records_by(
      records: @owner.where(id: @first.id),
      filter: {type: 'root_scope_boundary_review', id: @second.id}
    ).relation

    expect(result.ids).to eq([])
  end

  it 'keeps an explicit successful root result as an intentional skip' do
    custom_filter = Class.new(Scry::Filters::Base) do
      def apply = success(@scope)
    end
    Scry.configuration.register_filter(:root_nil_boundary_review, custom_filter)

    result = Scry.filter_records_by(
      records: @owner.where(id: @first.id),
      filter: {type: 'root_nil_boundary_review'}
    ).relation

    expect(result.ids).to eq([@first.id])
  end

  it 'rejects a non-relation root custom result' do
    custom_filter = Class.new(Scry::Filters::Base) do
      def apply = :not_a_relation
    end
    Scry.configuration.register_filter(:root_nonrelation_boundary_review, custom_filter)

    expect {
      Scry.filter_records_by(
        records: @owner.where(id: @first.id),
        filter: {type: 'root_nonrelation_boundary_review'}
      ).relation
    }.to raise_error(Scry::FilterError, /current model/)
  end

  it 'rejects a root custom relation for another model' do
    custom_filter = Class.new(Scry::Filters::Base) do
      def apply
        success(@model.reflect_on_association(:children).klass.all)
      end
    end
    Scry.configuration.register_filter(:root_model_boundary_review, custom_filter)

    expect {
      Scry.filter_records_by(
        records: @owner.where(id: @first.id),
        filter: {type: 'root_model_boundary_review'}
      ).relation
    }.to raise_error(Scry::FilterError, /current model/)
  end
end
