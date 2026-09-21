# frozen_string_literal: true

RSpec.shared_examples 'candidate projection contracts' do
  %w[has_any has_all only_has_any only_has_all].each do |predicate|
    it "rejects a DISTINCT projection without its primary key for #{predicate}" do
      candidates = @child.select(:name).distinct
      expect { boundary_filter(boundary_association(predicate, candidates)) }
        .to raise_error(Scry::FilterError, /projection.*primary key/)
    end
  end

  it 'rejects a primary key projected under another name' do
    candidates = @child.select(@child.arel_table[:id].as('candidate_id')).distinct
    expect { boundary_filter(boundary_association('has_all', candidates)) }
      .to raise_error(Scry::FilterError, /projection.*primary key/)
  end

  it 'rejects a candidate primary-key alias sourced from the joined owner table' do
    candidates = @child.joins(:owner).select(@owner.arel_table[:id].as('id')).distinct
    expect { boundary_filter(boundary_association('has_any', candidates)) }
      .to raise_error(Scry::FilterError, /candidate projection.*candidate relation|primary key/)
  end

  it 'rejects a readable SQL primary-key alias sourced from the joined owner table' do
    candidates = @child.joins(:owner).select("#{@owner.table_name}.id AS id").distinct
    expect { boundary_filter(boundary_association('has_any', candidates)) }
      .to raise_error(Scry::FilterError, /candidate projection.*candidate relation|primary key/)
  end

  it 'preserves a DISTINCT primary-key projection with ordering and pagination' do
    candidates = @child.select(:id, :name).distinct.order(name: :desc).limit(1)
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@second.id])
  end

  it 'preserves a selected computed alias through joined DISTINCT pagination' do
    candidates = @child
      .joins('CROSS JOIN (SELECT 1 AS copy UNION ALL SELECT 2 AS copy) copies')
      .select("#{@child.table_name}.id, (#{@child.table_name}.amount * 2) AS ranking")
      .distinct
      .order(Arel.sql('ranking DESC'))
      .limit(1)

    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@second.id])
  end

  it 'accepts a primary key explicitly aliased to its original name' do
    candidates = @child.where(id: @a.id).select(@child.arel_table[:id].as('id')).distinct
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@first.id])
  end

  it 'accepts a qualified wildcard projection' do
    candidates = @child.where(id: @a.id).select("#{@child.table_name}.*").distinct
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@first.id])
  end

  it 'accepts a simple SQL projection list containing the primary key' do
    candidates = @child.where(id: @a.id).select('id, name').distinct
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@first.id])
  end

  it 'validates the configured primary key rather than assuming id' do
    @child.primary_key = 'name'
    candidates = @child.where(name: 'a').select(:name).distinct
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@first.id])
    expect { boundary_filter(boundary_association('has_all', @child.select(:id).distinct)) }
      .to raise_error(Scry::FilterError, /projection.*primary key/)
  end

  it 'retains normalization of ordinary candidate projections before pagination' do
    candidates = @child.select(:name).order(:id).limit(1)
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@first.id])
  end

  %w[has_any has_all only_has_any only_has_all].each do |predicate|
    it "rejects a raw Arel candidate without the primary key for #{predicate}" do
      candidates = @child.select(:name).arel
      expect { boundary_filter(boundary_association(predicate, candidates)) }
        .to raise_error(Scry::FilterError, /projection.*primary key/)
    end
  end

  it 'rejects a multi-column raw Arel candidate even when it contains the key' do
    candidates = @child.select(:id, :name).arel
    expect { boundary_filter(boundary_association('has_any', candidates)) }
      .to raise_error(Scry::FilterError, /projection.*primary key/)
  end

  it 'accepts a raw Arel candidate selecting only its canonical key' do
    candidates = @child.where(id: @a.id).select(@child.arel_table[:id].as('id')).arel
    expect(boundary_filter(boundary_association('has_all', candidates)).ids).to eq([@first.id])
  end

  it 'requires an explicit key when SQL expressions cannot establish the projection' do
    candidates = @child.select(Arel.sql("COALESCE(name, 'id, name')")).distinct
    expect { boundary_filter(boundary_association('has_all', candidates)) }
      .to raise_error(Scry::FilterError, /projection.*primary key/)
  end

  it 'does not mistake delimiters inside a quoted identifier for a primary-key projection' do
    candidates = @child.select(Arel.sql('"name,id"')).distinct
    expect { boundary_filter(boundary_association('has_all', candidates)) }
      .to raise_error(Scry::FilterError, /projection.*primary key/)
  end

  %i[ignore warn].each do |mode|
    it "reports invalid candidate projections before execution in #{mode} mode" do
      Scry.configuration.invalid_filter_policy = :skip
      Scry.configuration.diagnostic_logging = mode == :warn ? :warn : :silent
      result = Scry.filter_records_by(records: @owner,
        filter: boundary_group(boundary_association('has_all', @child.select(:name).distinct)))
      expect(result.diagnostics.map(&:message).join).to match(/projection.*primary key/)
      expect(result.relation.ids).to contain_exactly(@first.id, @second.id)
    end
  end
end
