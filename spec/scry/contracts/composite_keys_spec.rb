# frozen_string_literal: true

require "rails_helper"
require_relative "../interoperability/temporary_table_support"

RSpec.describe "composite primary key filtering", :interoperability do
  before(:all) do
    Arel::Predications.module_eval do
      define_method(:has_at_least_two_association_contract) do |value|
        Scry::AssociationQuery.for_attribute(self)
          .owner_count_at_least(value, minimum: 2)
      end
    end unless Arel::Predications.method_defined?(:has_at_least_two_association_contract)

    Scry.install_arel_extensions!
  end

  it "filters a composite-key relation by a property" do
    with_temporary_table(
      "af_composite_filter_parents",
      "tenant_id bigint NOT NULL, code varchar NOT NULL, label varchar NOT NULL, PRIMARY KEY (tenant_id, code)"
    ) do |table|
      parent = temporary_model("InteroperabilityTemporary::CompositeFilterParent", table)
      parent.primary_key = %w[tenant_id code]
      parent.create!(tenant_id: 1, code: "a", label: "match")
      parent.create!(tenant_id: 1, code: "b", label: "other")

      filter = {
        type: "group",
        predicate: "and",
        filters: [{type: "property", property: "label", predicate: "eq", args: ["match"]}]
      }

      expect(Scry.filter_records_by(records: parent, filter: filter).relation
        .pluck(:tenant_id, :code)).to eq([[1, "a"]])
    end
  end

  it "matches an association through composite parent and child keys" do
    with_temporary_table(
      "af_composite_association_parents",
      "tenant_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (tenant_id, code)"
    ) do |parents|
      with_temporary_table(
        "af_composite_association_children",
        "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, code varchar NOT NULL, label varchar NOT NULL"
      ) do |children|
        parent = temporary_model("InteroperabilityTemporary::CompositeAssociationParent", parents)
        child = temporary_model("InteroperabilityTemporary::CompositeAssociationChild", children)
        parent.primary_key = %w[tenant_id code]
        parent.query_constraints :tenant_id, :code
        child.query_constraints :tenant_id, :code
        parent.has_many :children, class_name: child.name, foreign_key: %i[tenant_id code]

        parent.create!(tenant_id: 1, code: "a")
        parent.create!(tenant_id: 1, code: "b")
        parent.create!(tenant_id: 2, code: "a")
        child.create!(id: 1, tenant_id: 1, code: "a", label: "linked")
        child.create!(id: 2, tenant_id: 2, code: "a", label: "other-tenant")

        %w[has_any has_all only_has_any only_has_all].each do |predicate|
          filter = {
            type: "group", predicate: "and", filters: [{
              type: "association", association: "children", predicate:, args: [[1]]
            }]
          }

          expect(Scry.filter_records_by(records: parent, filter: filter).relation
            .pluck(:tenant_id, :code)).to eq([[1, "a"]]), predicate
        end

        malformed = {
          type: "group", predicate: "and", filters: [{
              type: "association", association: "children", predicate: "has_any", args: [["bad"]]
          }]
        }
        Scry.configuration.with_temporary_settings do |config|
          config.invalid_filter_policy = :raise
          expect { Scry.filter_records_by(records: parent, filter: malformed).relation }
            .to raise_error(Scry::FilterError, /id|key|composite|shape|arity/)
        end
      end
    end
  end

  it "supports a direct Arel association predicate with composite owner keys" do
    with_temporary_table(
      "af_custom_arel_composite_owners",
      "tenant_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (tenant_id, code)"
    ) do |owners|
      with_temporary_table(
        "af_custom_arel_composite_children",
        "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, code varchar NOT NULL"
      ) do |children|
        owner = temporary_model("InteroperabilityTemporary::CustomArelCompositeOwner", owners)
        child = temporary_model("InteroperabilityTemporary::CustomArelCompositeChild", children)
        owner.primary_key = %w[tenant_id code]
        owner.query_constraints :tenant_id, :code
        child.query_constraints :tenant_id, :code
        owner.has_many :children, class_name: child.name, foreign_key: %i[tenant_id code]

        matching = owner.create!(tenant_id: 1, code: "a")
        other = owner.create!(tenant_id: 1, code: "b")
        child.create!(id: 1, tenant_id: matching.tenant_id, code: matching.code)
        child.create!(id: 2, tenant_id: matching.tenant_id, code: matching.code)
        child.create!(id: 3, tenant_id: other.tenant_id, code: other.code)

        attribute = owner.arel_table[:children]
        result = owner.where(attribute.has_at_least_two_association_contract([1, 2]))

        expect(result.pluck(:tenant_id, :code)).to eq([[1, "a"]])
      end
    end
  end

  it "matches limited associations through composite child keys" do
    with_temporary_table(
      "af_limited_composite_owners",
      "id bigint PRIMARY KEY, name varchar NOT NULL"
    ) do |owners|
      with_temporary_table(
        "af_limited_composite_children",
        "owner_id bigint NOT NULL, code varchar NOT NULL, position bigint NOT NULL, PRIMARY KEY (owner_id, code)"
      ) do |children|
        owner = temporary_model("InteroperabilityTemporary::LimitedCompositeOwner", owners)
        child = temporary_model("InteroperabilityTemporary::LimitedCompositeChild", children)
        child.primary_key = %w[owner_id code]
        owner.has_many :latest_children, -> { order(position: :desc).limit(1) },
          class_name: child.name, foreign_key: :owner_id
        [owner, child].each { |model| model.include(Scry::Filterable) }

        record = owner.create!(id: 1, name: "owner")
        other = owner.create!(id: 2, name: "other")
        child.create!(owner_id: record.id, code: "old", position: 1)
        child.create!(owner_id: record.id, code: "new", position: 2)
        child.create!(owner_id: other.id, code: "new", position: 2)

        %w[has_any only_has_any].each do |predicate|
          filter = {
            type: "group", predicate: "and", filters: [{
              type: "association", association: "latest_children", predicate:,
              args: [[[record.id, "new"]]]
            }]
          }

          expect(Scry.filter_records_by(records: owner, filter:).relation.ids)
            .to eq([record.id]), predicate

          filter[:filters].first[:args] = [[[other.id, "new"]]]
          expect(Scry.filter_records_by(records: owner.where(id: record.id), filter:).relation.ids)
            .to eq([]), "#{predicate} must compare the complete child key"
        end
      end
    end
  end

  it "counts distinct composite child identities instead of only the first key" do
    with_temporary_table("af_distinct_count_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_distinct_count_children",
        "owner_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (owner_id, code)"
      ) do |children|
        owner = temporary_model("InteroperabilityTemporary::DistinctCountOwner", owners)
        child = temporary_model("InteroperabilityTemporary::DistinctCountChild", children)
        child.primary_key = %w[owner_id code]
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id

        record = owner.create!(id: 1)
        child.create!(owner_id: record.id, code: "a")
        child.create!(owner_id: record.id, code: "b")

        filter = {
          type: "group", predicate: "and", filters: [{
            type: "aggregate", association: "children", aggregate: "count",
            predicate: "eq", args: [2], "distinct?" => true
          }]
        }

        expect(Scry.filter_records_by(records: owner, filter:).relation.ids).to eq([record.id])
      end
    end
  end

  it "matches all composite candidates while only_has_all rejects an outside code" do
    with_temporary_table("af_cpk_set_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_cpk_set_children",
        "owner_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (owner_id, code)"
      ) do |children|
        owner = temporary_model("InteroperabilityTemporary::CpkSetOwner", owners)
        child = temporary_model("InteroperabilityTemporary::CpkSetChild", children)
        child.primary_key = %w[owner_id code]
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        record = owner.create!(id: 1)
        child.create!(owner_id: record.id, code: "a")
        child.create!(owner_id: record.id, code: "b")
        child.create!(owner_id: record.id, code: "outside")
        candidates = [[record.id, "a"], [record.id, "b"]]

        expect(Scry.filter_records_by(
          records: owner,
          filter: { type: "group", predicate: "and", filters: [{
            type: "association", association: "children", predicate: "has_all", args: [candidates]
          }] }
        ).relation.ids).to eq([record.id])
        expect(Scry.filter_records_by(
          records: owner,
          filter: { type: "group", predicate: "and", filters: [{
            type: "association", association: "children", predicate: "only_has_all", args: [candidates]
          }] }
        ).relation.ids).to eq([])
      end
    end
  end

  it "preserves a custom count builder under composite distinct aggregation" do
    with_temporary_table("af_custom_count_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_custom_count_children",
        "owner_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (owner_id, code)"
      ) do |children|
        owner = temporary_model("InteroperabilityTemporary::CustomCountOwner", owners)
        child = temporary_model("InteroperabilityTemporary::CustomCountChild", children)
        child.primary_key = %w[owner_id code]
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        record = owner.create!(id: 1)
        child.create!(owner_id: record.id, code: "a")
        child.create!(owner_id: record.id, code: "b")

        seen_distinct = nil
        Scry.configuration.with_temporary_settings do |config|
          config.register_aggregate(:count, types: [:all], result_type: :integer, property: false) do |_attribute, distinct|
            seen_distinct = distinct
            Arel::Nodes.build_quoted(7)
          end
          filter = {
            type: "group", predicate: "and", filters: [{
              type: "aggregate", association: "children", aggregate: "count",
              predicate: "eq", args: [7], "distinct?" => true
            }]
          }

          expect(Scry.filter_records_by(records: owner, filter:).relation.ids).to eq([record.id])
        end
        expect(seen_distinct).to be(true)
      end
    end
  end

  it "validates every composite key column for raw Arel association candidates" do
    with_temporary_table("af_arel_cpk_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_arel_cpk_children",
        "owner_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (owner_id, code)"
      ) do |children|
        owner = temporary_model("InteroperabilityTemporary::ArelCpkOwner", owners)
        child = temporary_model("InteroperabilityTemporary::ArelCpkChild", children)
        child.primary_key = %w[owner_id code]
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id

        owner.create!(id: 1)
        owner.create!(id: 2)
        child.create!(owner_id: 1, code: "a")
        child.create!(owner_id: 1, code: "b")
        child.create!(owner_id: 2, code: "a")

        incomplete = child.select(:owner_id).arel
        Scry.configuration.with_temporary_settings do |config|
          config.invalid_filter_policy = :raise
          %w[has_any has_all only_has_any only_has_all].each do |predicate|
            expect {
              Scry.filter_records_by(
                records: owner,
                filter: {
                  type: "group", predicate: "and", filters: [{
                    type: "association", association: "children", predicate:, args: [incomplete]
                  }]
                }
              ).relation
            }.to raise_error(Scry::FilterError, /projection.*primary key/), predicate
          end
        end

        complete = child.where(code: "a").select(:owner_id, :code).arel
        expect(Scry.filter_records_by(
          records: owner,
          filter: {
            type: "group", predicate: "and", filters: [{
              type: "association", association: "children", predicate: "has_any", args: [complete]
            }]
          }
        ).relation.ids).to contain_exactly(1, 2)
      end
    end
  end

end
