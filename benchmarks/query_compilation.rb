# frozen_string_literal: true

require_relative '../lib/rails_scry'
require 'benchmark'
require 'json'

def bounded_integer(name, default, range)
  value = Integer(ENV.fetch(name, default.to_s))
  raise ArgumentError, "#{name} must be between #{range.begin} and #{range.end}" unless range.cover?(value)
  value
end

iterations = bounded_integer('ITERATIONS', 50, 1..10_000)
owner_count = bounded_integer('OWNERS', 1_000, 1..10_000)
children_per_owner = bounded_integer('CHILDREN', 8, 1..30)
tags_per_child = bounded_integer('TAGS', 3, 1..10)
candidate_count = bounded_integer('CANDIDATES', 500, 1..10_000)
tenant_count = bounded_integer('TENANTS', 10, 1..100)
raise ArgumentError, 'The requested dataset exceeds 1,000,000 rows' if owner_count * (1 + children_per_owner * (1 + tags_per_child)) > 1_000_000

ActiveRecord::Base.establish_connection(adapter: 'postgresql', database: ENV.fetch('PGDATABASE', 'scry_test'))

module FilterBenchmark
  class Owner < ActiveRecord::Base
    self.table_name = 'af_bench_owners'
    self.primary_key = 'id'
    include Scry::Filterable
    has_many :children, class_name: 'FilterBenchmark::Child', foreign_key: :owner_id
  end

  class Child < ActiveRecord::Base
    self.table_name = 'af_bench_children'
    self.primary_key = 'id'
    include Scry::Filterable
    has_many :tags, class_name: 'FilterBenchmark::Tag', foreign_key: :child_id
  end

  class Tag < ActiveRecord::Base
    self.table_name = 'af_bench_tags'
    self.primary_key = 'id'
    include Scry::Filterable
  end
end

def group(*children, predicate: 'and')
  {predicate: predicate, value: children}
end

def property(name, value)
  {type: 'property', property: name, predicate: 'eq', value: value}
end

def insert_rows(connection, model, rows)
  rows.each_slice(1_000) do |batch|
    keys = batch.first.keys
    columns = keys.map { |key| connection.quote_column_name(key) }.join(', ')
    values = batch.map { |row| "(#{keys.map { |key| connection.quote(row.fetch(key)) }.join(', ')})" }.join(', ')
    connection.execute("INSERT INTO #{connection.quote_table_name(model.table_name)} (#{columns}) VALUES #{values}")
  end
end

Scry.configuration.error_handling = :raise
Scry.configuration.max_filter_nodes = candidate_count + 5_000
ActiveRecord::Base.connection_pool.with_connection do |connection|
  connection.transaction(requires_new: true) do
    connection.create_table(:af_bench_owners, temporary: true) do |table|
      table.string :name
      table.integer :tenant_id, null: false
      table.index :tenant_id
    end
    connection.create_table(:af_bench_children, temporary: true) do |table|
      table.bigint :owner_id, null: false
      table.boolean :active, null: false
      table.index :owner_id
    end
    connection.create_table(:af_bench_tags, temporary: true) do |table|
      table.bigint :child_id, null: false
      table.string :label, null: false
      table.index :child_id
    end
    owners = (1..owner_count).map { |id| {id: id, name: "owner-#{id}", tenant_id: (id - 1) % tenant_count} }
    insert_rows(connection, FilterBenchmark::Owner, owners)
    children = owners.flat_map do |owner|
      next [] if owner[:id] % 10 == 0
      children_per_owner.times.map { |index| {owner_id: owner[:id], active: index.even?} }
    end
    children.each_with_index { |row, index| row[:id] = index + 1 }
    insert_rows(connection, FilterBenchmark::Child, children)
    tags = children.flat_map do |child|
      tags_per_child.times.map { |index| {child_id: child[:id], label: index.zero? ? 'marker' : 'other'} }
    end
    insert_rows(connection, FilterBenchmark::Tag, tags)
    %w[af_bench_owners af_bench_children af_bench_tags].each { |table| connection.execute("ANALYZE #{table}") }

    sizes = {owners: owners.size, children: children.size, tags: tags.size, candidates: [candidate_count, children.size].min}
    puts JSON.generate(dataset: sizes.merge(tenants: tenant_count), ruby: RUBY_VERSION, active_record: ActiveRecord.version.to_s)
    aggregate = {type: 'aggregate', association: 'children', aggregate: 'count', predicate: 'gt', value: 0}
    nested_scope = group({type: 'association', association: 'tags', predicate: 'has_any', scoping: group(property('label', 'marker'))})
    candidate_ids = children.first(candidate_count).map { |child| child[:id] }
    candidate_owner_ids = children.first(candidate_count).map { |child| child[:owner_id] }.uniq
    cases = {
      property: [group(property('name', 'owner-1')), 1],
      aggregate_or_property: [group(aggregate, property('name', 'owner-10'), predicate: 'or'),
        owner_count - (owner_count / 10) + (owner_count >= 10 ? 1 : 0)],
      zero_count: [group(aggregate.merge(predicate: 'eq', include_zero?: true)), (1..owner_count).count { |id| (id % 10).zero? }],
      fifty_properties: [group(*Array.new(50) { |index| property('name', "owner-#{index + 1}") }, predicate: 'or'), [owner_count, 50].min],
      nested_scoped_has_all: [group({type: 'association', association: 'children', predicate: 'has_all', scoping: nested_scope}), owner_count == 1 ? 1 : 0],
      nested_scoped_only_has_all: [group({type: 'association', association: 'children', predicate: 'only_has_all', scoping: nested_scope}), owner_count == 1 ? 1 : 0],
      large_candidates: [group({type: 'association', association: 'children', predicate: 'has_any', value: candidate_ids}), candidate_owner_ids.length]
    }
    page = FilterBenchmark::Child.where(owner_id: 1).order(id: :desc).limit(children_per_owner)
    cases[:tenant_paginated_has_all] = [group({type: 'association', association: 'children', predicate: 'has_all', value: page}), 1]
    cases[:tenant_paginated_only_has_all] = [group({type: 'association', association: 'children', predicate: 'only_has_all', value: page}), 1]
    cases.each do |name, (definition, expected_matches)|
      scope = name.to_s.start_with?('tenant_') ? FilterBenchmark::Owner.where(tenant_id: 0) : FilterBenchmark::Owner.all
      compile = -> { Scry.filter_records_by(records: scope, filter: definition) }
      sql = compile.call.to_sql
      elapsed = Benchmark.realtime { iterations.times { raise 'SQL changed between iterations' unless compile.call.to_sql == sql } }
      matched_owners = compile.call.count
      raise "#{name} cardinality mismatch: expected #{expected_matches}, got #{matched_owners}" unless matched_owners == expected_matches
      result = {case: name, iterations: iterations, compile_ms: (elapsed * 1_000 / iterations).round(3), sql_bytes: sql.bytesize, candidate_subqueries: sql.scan(/\) scry_selected/).size, matched_owners: matched_owners, expected_matches: expected_matches}
      if ENV['EXPLAIN'] == '1'
        result[:plan] = JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}"))
      end
      puts JSON.generate(result)
    end
    raise ActiveRecord::Rollback
  end
end
