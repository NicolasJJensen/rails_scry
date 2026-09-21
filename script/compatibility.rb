#!/usr/bin/env ruby
# frozen_string_literal: true

gem "activerecord", "~> #{ENV.fetch('RAILS_VERSION', '8.1')}.0"
require "logger"
require "active_record"
require_relative "../lib/rails_scry"

puts "ActiveRecord #{ActiveRecord.version}, Ruby #{RUBY_VERSION}, checkout #{File.expand_path('../lib', __dir__)}"

adapter = ENV.fetch("SCRY_ADAPTER", "sqlite3")
connection = case adapter
when "sqlite3"
  { adapter: "sqlite3", database: ":memory:" }
when "mysql2"
  {
    adapter: "mysql2",
    host: ENV.fetch("MYSQL_HOST", "127.0.0.1"),
    port: ENV.fetch("MYSQL_PORT", "3306"),
    username: ENV.fetch("MYSQL_USER", "root"),
    password: ENV.fetch("MYSQL_PASSWORD", "root"),
    database: ENV.fetch("MYSQL_DATABASE", "scry_test")
  }
else
  abort("unsupported SCRY_ADAPTER=#{adapter.inspect}; use sqlite3 or mysql2")
end

ActiveRecord::Base.establish_connection(connection)

at_exit do
  %i[compat_nodes compat_assets compat_groups compat_children compat_owners].each do |table|
    ActiveRecord::Base.connection.drop_table(table, if_exists: true)
  end
end

ActiveRecord::Schema.define do
  create_table :compat_owners, temporary: ActiveRecord::Base.connection.adapter_name != "Mysql2" do |table|
    table.string :name, null: false
    table.integer :tenant_id, null: false
    table.date :joined_on
    table.string :code
  end

  create_table :compat_children, temporary: ActiveRecord::Base.connection.adapter_name != "Mysql2" do |table|
    table.integer :owner_id, null: false
    table.boolean :active, null: false, default: false
  end

  create_table :compat_groups, temporary: ActiveRecord::Base.connection.adapter_name != "Mysql2" do |table|
    table.integer :owner_id, null: false
  end

  create_table :compat_assets, temporary: ActiveRecord::Base.connection.adapter_name != "Mysql2" do |table|
    table.integer :group_id, null: false
    table.string :token, null: false
  end

  create_table :compat_nodes, temporary: ActiveRecord::Base.connection.adapter_name != "Mysql2" do |table|
    table.integer :parent_id
    table.string :name, null: false
  end
end

class CompatOwner < ActiveRecord::Base
  self.table_name = "compat_owners"
  include Scry::Filterable

  attribute :code, Class.new(ActiveRecord::Type::String) {
    def serialize(value)
      value&.upcase
    end
  }.new

  has_many :compat_children, class_name: "CompatChild", foreign_key: :owner_id
  has_many :active_children, -> { where(active: true) }, class_name: "CompatChild", foreign_key: :owner_id
  has_many :compat_groups, class_name: "CompatGroup", foreign_key: :owner_id
  has_many :compat_assets, through: :compat_groups
end

class CompatChild < ActiveRecord::Base
  self.table_name = "compat_children"
  include Scry::Filterable
  belongs_to :compat_owner, class_name: "CompatOwner", foreign_key: :owner_id
end

class CompatGroup < ActiveRecord::Base
  self.table_name = "compat_groups"
  include Scry::Filterable
  belongs_to :compat_owner, class_name: "CompatOwner", foreign_key: :owner_id
  has_many :compat_assets, class_name: "CompatAsset", foreign_key: :group_id
end

class CompatAsset < ActiveRecord::Base
  self.table_name = "compat_assets"
  include Scry::Filterable
  belongs_to :compat_group, class_name: "CompatGroup", foreign_key: :group_id
end

class CompatNode < ActiveRecord::Base
  self.table_name = "compat_nodes"
  belongs_to :parent, class_name: "CompatNode", optional: true, foreign_key: :parent_id
  has_many :children, class_name: "CompatNode", foreign_key: :parent_id
  include Scry::Filterable
end

def group(*children, predicate: "and", negate: false)
  { type: "group", predicate: predicate, filters: children, negate: negate }
end

def property(name, predicate, value = nil)
  args = %w[eq_nil not_eq_nil eq_true eq_false].include?(predicate.to_s) ? [] : [value]
  { type: "property", property: name, predicate: predicate, args: }
end

def association(name, predicate, value = nil, **options)
  args = options.key?(:scoping) && value.nil? ? [] : [value]
  { type: "association", association: name, predicate: predicate, args:, **options }
end

def count(association_name, predicate, value, **options)
  {
    type: "aggregate",
    association: association_name,
    aggregate: "count",
    predicate: predicate,
    args: [value],
    **options
  }
end

def assert!(condition, message)
  abort("FAIL: #{message}") unless condition
  puts "PASS: #{message}"
end

def filter(scope, definition)
  Scry.filter_records_by(records: scope, filter: definition, context: nil).relation
end

def reset_records!
  [CompatAsset, CompatGroup, CompatChild, CompatOwner, CompatNode].each(&:delete_all)
  Scry.clear_thread_caches!
end

Scry.configuration.invalid_filter_policy = :skip
Scry.configuration.callback_error_policy = :raise

reset_records!

scoped_owner = CompatOwner.create!(name: "scoped", tenant_id: 1)
inactive_child = CompatChild.create!(compat_owner: scoped_owner, active: false)
scoped_matches = filter(
  CompatOwner.all,
  group(association("active_children", "has_any", [inactive_child.id]))
).pluck(:id)
assert!(scoped_matches.empty?, "scoped association membership excludes inactive children")

reset_records!

has_child = CompatOwner.create!(name: "has-child", tenant_id: 1)
named_owner = CompatOwner.create!(name: "named", tenant_id: 1)
CompatChild.create!(compat_owner: has_child, active: true)
aggregate_or = group(
  count("compat_children", "gt", 0),
  property("name", "eq", "named"),
  predicate: "or"
)
aggregate_or_matches = filter(CompatOwner.all, aggregate_or).pluck(:id)
assert!(aggregate_or_matches.sort == [has_child.id, named_owner.id].sort, "aggregate OR composes with property filters")

reset_records!

scoped_has_child = CompatOwner.create!(name: "scoped-child", tenant_id: 7)
scoped_no_child = CompatOwner.create!(name: "scoped-empty", tenant_id: 7)
CompatOwner.create!(name: "other-tenant", tenant_id: 8)
CompatChild.create!(compat_owner: scoped_has_child, active: true)
negated_count = count("compat_children", "gt", 0, negate: true)
negated_count_matches = filter(CompatOwner.where(tenant_id: 7), group(negated_count)).pluck(:id)
assert!(negated_count_matches == [scoped_no_child.id], "negated aggregate preserves the caller scope")

reset_records!

zero_owner = CompatOwner.create!(name: "zero", tenant_id: 1)
nonzero_owner = CompatOwner.create!(name: "nonzero", tenant_id: 1)
CompatChild.create!(compat_owner: nonzero_owner, active: true)
zero_count = count("compat_children", "eq", 0)
zero_count_matches = filter(CompatOwner.all, group(zero_count)).pluck(:id)
assert!(zero_count_matches == [zero_owner.id], "zero-inclusive count returns parents without children")

reset_records!

through_owner = CompatOwner.create!(name: "through", tenant_id: 1)
through_group = CompatGroup.create!(compat_owner: through_owner)
through_asset = CompatAsset.create!(compat_group: through_group, token: "visible")
through_matches = filter(
  CompatOwner.all,
  group(association("compat_assets", "has_any", [through_asset.id]))
).pluck(:id)
assert!(through_matches == [through_owner.id], "through association membership follows Rails reflections")
nested = group(association("compat_groups", "has_any", scoping: group(
  association("compat_assets", "has_any", scoping: group(property("token", "eq", "visible")))
)))
assert!(filter(CompatOwner.all, nested).ids == [through_owner.id], "nested association scopes execute")

reset_records!

self_root = CompatNode.create!(name: "root")
self_child = CompatNode.create!(name: "child", parent: self_root)
CompatNode.create!(name: "other")
self_membership = filter(
  CompatNode.all,
  group(association("children", "has_any", [self_child.id]))
).pluck(:id)
assert!(self_membership == [self_root.id], "self-referential association membership uses child aliases")
self_count = filter(
  CompatNode.all,
  group(count("children", "gt", 0))
).pluck(:id)
assert!(self_count == [self_root.id], "self-referential aggregate count uses child aliases")

reset_records!

first = CompatOwner.create!(name: "rate_50%", tenant_id: 9, joined_on: Date.new(2026, 1, 2), code: "mixed")
second = CompatOwner.create!(name: "rateX50percent", tenant_id: 9, joined_on: Date.new(2025, 1, 2))
CompatOwner.create!(name: "outside", tenant_id: 10)
CompatChild.create!(compat_owner: first, active: true)

assert!(filter(CompatOwner.all, group(property("joined_on", "eq", "2026-01-02"))).ids == [first.id], "date comparison accepts a serialized date")
assert!(filter(CompatOwner.all, group(property("joined_on", "eq_nil"))).count == 1, "temporal nil predicates execute")
assert!(filter(CompatChild.all, group(property("active", "eq_true"))).count == 1, "boolean predicates execute")
assert!(filter(CompatOwner.all, group(property("name", "matches", "_50%"))).ids == [first.id], "text matching escapes percent and underscore")
assert!(filter(CompatOwner.all, group(property("code", "eq", "mixed"))).ids == [first.id], "custom attribute serializers apply")
assert!(filter(CompatOwner.all, group(count("compat_children", "eq", "1"))).ids == [first.id], "aggregate counts normalize numeric strings")
child_id = CompatChild.first.id
assert!(filter(CompatOwner.all, group(association("compat_children", "has_all", [child_id, child_id + 100_000]))).empty?, "has_all retains missing requested IDs")
empty_scope = group(property("id", "eq", child_id + 100_000))
assert!(filter(CompatOwner.all, group(association("compat_children", "has_all", scoping: empty_scope))).count == 3, "has_all preserves the empty scoped set identity")

Scry.configuration.register_aggregate(:contract_count, property: false, result_type: :integer, empty_value: 0) do |attribute, distinct|
  attribute.count(distinct)
end
custom_count = count("compat_children", "eq", 1).merge(aggregate: "contract_count")
assert!(filter(CompatOwner.all, group(custom_count)).ids == [first.id], "custom aggregate builders execute")

input = CompatOwner.where(tenant_id: 9).order(:id).limit(1).offset(1)
assert!(filter(input, group(property("name", "not_eq", "outside"))).ids == [second.id], "caller tenant scope, ordering, limit, and offset remain intact")
Scry.configuration.invalid_filter_policy = :skip
Scry.configuration.callback_error_policy = :raise
result = Scry.filter_records_by(records: CompatOwner, filter: group(property("missing_column", "eq", 1)))
assert!(result.diagnostics.any? { |diagnostic| diagnostic.code == :property_denied }, "invalid property filters return diagnostics")

puts "#{adapter} association and aggregate contracts: PASS"
