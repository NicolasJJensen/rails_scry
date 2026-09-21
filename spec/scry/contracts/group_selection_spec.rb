# frozen_string_literal: true

require "rails_helper"
require_relative "../interoperability/temporary_table_support"

RSpec.describe "group selection modifiers", :interoperability do
  def property_filter(property, predicate, value)
    {type: "property", property: property, predicate: predicate, args: [value]}
  end

  it "orders, offsets, and limits a root group" do
    with_temporary_table(
      "af_group_selection_records",
      "id bigint PRIMARY KEY, amount bigint NOT NULL, label varchar NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::GroupSelectionRecord", table)
      record.create!(id: 1, amount: 300, label: "highest")
      record.create!(id: 2, amount: 200, label: "middle")
      record.create!(id: 3, amount: 100, label: "lowest")

      filter = {
        type: "group",
        predicate: "and",
        filters: [property_filter("amount", "gteq", 0)],
        order: [{property: "amount", direction: "desc"}],
        limit: 1,
        offset: 1
      }

      expect(Scry.filter_records_by(records: record, filter: filter).relation.pluck(:id)).to eq([2])
    end
  end

  it "keeps caller ordering and pagination on the final relation" do
    with_temporary_table(
      "af_group_caller_relation",
      "id bigint PRIMARY KEY, amount bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::GroupCallerRelation", table)
      record.create!(id: 1, amount: 10)
      record.create!(id: 2, amount: 20)
      record.create!(id: 3, amount: 30)
      caller_scope = record.order(id: :desc).limit(2)
      filter = {type: "group", predicate: "and", filters: [property_filter("amount", "gteq", 0)]}

      expect(Scry.filter_records_by(records: caller_scope, filter:).relation.pluck(:id)).to eq([3, 2])
    end
  end

  it "accepts JSON order expressions with literal operands" do
    with_temporary_table(
      "af_group_json_order",
      "id bigint PRIMARY KEY, amount bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::GroupJsonOrder", table)
      record.create!(id: 1, amount: 10)
      record.create!(id: 2, amount: 20)
      filter = {
        type: "group", predicate: "and", filters: [property_filter("amount", "gteq", 0)],
        order: [{expression: {operator: "subtract", operands: [{property: "amount"}, {literal: 1}]}, direction: "desc"}],
        limit: 1
      }

      expect(Scry.filter_records_by(records: record, filter: JSON.parse(JSON.generate(filter))).relation.ids)
        .to eq([2])
    end
  end

  it "orders computed expressions against a derived relation source" do
    with_temporary_table(
      "af_group_derived_order",
      "id bigint PRIMARY KEY, amount bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::GroupDerivedOrder", table)
      first = record.create!(id: 1, amount: 7)
      second = record.create!(id: 2, amount: 2)
      arel_table = record.arel_table
      derived = arel_table.project(
        arel_table[:id],
        (arel_table[:amount] * 2).as("amount")
      ).as("derived_records")
      records = record.select(:id, :amount).from(derived)
      filter = {
        type: "group", predicate: "and",
        filters: [{type: "property", property: "id", predicate: "gteq", args: [0]}],
        order: [{
          expression: {
            operator: "add",
            operands: [{property: "amount"}, {literal: 1}]
          },
          direction: "desc"
        }]
      }

      expect(records.pluck(:amount)).to contain_exactly(14, 4)
      expect(Scry.filter_records_by(records:, filter:).relation.ids).to eq([first.id, second.id])
    end
  end

  it "orders nested selections using values from the caller's derived source" do
    with_temporary_table(
      "af_nested_derived_group_order",
      "id bigint PRIMARY KEY, amount bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::NestedDerivedGroupOrder", table)
      first = record.create!(id: 1, amount: 1)
      record.create!(id: 2, amount: 10)

      source_table = record.arel_table
      source = source_table.project(
        source_table[:id],
        (source_table[:amount] * -1).as("amount")
      ).as("nested_derived_group_order_source")
      records = record.select(:id, :amount).from(source)
      filter = {
        type: "group", predicate: "and",
        filters: [{
          type: "group", predicate: "and",
          filters: [property_filter("id", "gteq", 0)],
          order: [{property: "amount", direction: "desc"}],
          limit: 1
        }]
      }

      expect(records.pluck(:amount)).to contain_exactly(-1, -10)
      expect(Scry.filter_records_by(records:, filter:).relation.ids).to eq([first.id])
    end
  end

  it "does not let a readable property bypass order permissions" do
    with_temporary_table(
      "af_group_order_permissions",
      "id bigint PRIMARY KEY, amount bigint NOT NULL, secret_amount bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::GroupOrderPermission", table)
      record.add_filter_permission(:order, list_type: :whitelist) { [:amount] }
      record.create!(id: 1, amount: 1, secret_amount: 20)
      record.create!(id: 2, amount: 2, secret_amount: 10)
      readable = {type: "group", predicate: "and", filters: [property_filter("amount", "gteq", 0)], order: [{property: "secret_amount", direction: "desc"}]}
      computed = {
        type: "group", predicate: "and", filters: [property_filter("amount", "gteq", 0)],
        order: [{expression: {operator: "add", operands: [{property: "secret_amount"}, {literal: 0}]}, direction: "desc"}]
      }

      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        expect { Scry.filter_records_by(records: record, filter: readable).relation }
          .to raise_error(Scry::FilterError, /order property/)
        expect { Scry.filter_records_by(records: record, filter: computed).relation }
          .to raise_error(Scry::FilterError, /order property/)
      end
    end
  end

  it "applies nested selection before combining a sibling condition" do
    with_temporary_table(
      "af_nested_group_selection_records",
      "id bigint PRIMARY KEY, amount bigint NOT NULL, label varchar NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::NestedGroupSelectionRecord", table)
      record.create!(id: 1, amount: 300, label: "highest")
      record.create!(id: 2, amount: 200, label: "target")
      record.create!(id: 3, amount: 100, label: "target")

      filter = {
        type: "group",
        predicate: "and",
        filters: [
          {
            type: "group",
            predicate: "and",
            filters: [property_filter("amount", "gteq", 0)],
            order: [{property: "amount", direction: "desc"}],
            limit: 1
          },
          property_filter("label", "eq", "target")
        ]
      }

      expect(Scry.filter_records_by(records: record, filter: filter).relation.pluck(:id)).to eq([])
    end
  end

  it "keeps root and nested selections inside the caller's default scope" do
    with_temporary_table(
      "af_scoped_group_selection_records",
      "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, amount bigint NOT NULL, label varchar NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ScopedGroupSelectionRecord", table)
      record.class_eval { default_scope { where(tenant_id: 7) } }
      record.create!(id: 1, tenant_id: 7, amount: 100, label: "visible")
      record.create!(id: 2, tenant_id: 8, amount: 900, label: "hidden")

      filter = {
        type: "group", predicate: "and",
        filters: [{
          type: "group", predicate: "and",
          filters: [property_filter("amount", "gteq", 0)],
          order: [{property: "amount", direction: "desc"}], limit: 1
        }]
      }

      expect(Scry.filter_records_by(records: record, filter:).relation.pluck(:id)).to eq([1])
    end
  end

  it "keeps a ranked group inside the caller scope through two ordinary groups" do
    with_temporary_table(
      "af_deep_scoped_group_selection",
      "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, amount bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::DeepScopedGroupSelection", table)
      record.class_eval { default_scope { where(tenant_id: 7) } }
      record.create!(id: 1, tenant_id: 7, amount: 100)
      record.create!(id: 2, tenant_id: 8, amount: 900)

      ranked = {
        type: "group", predicate: "and",
        filters: [property_filter("amount", "gteq", 0)],
        order: [{property: "amount", direction: "desc"}], limit: 1
      }
      nested = {
        type: "group", predicate: "and",
        filters: [{type: "group", predicate: "and", filters: [ranked]}]
      }

      expect(Scry.filter_records_by(records: record, filter: nested).relation.pluck(:id)).to eq([1])
    end
  end

  it "supports stable multi-column ordering and preserves child negation" do
    with_temporary_table(
      "af_group_selection_ties",
      "id bigint PRIMARY KEY, amount bigint NOT NULL, label varchar NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::GroupSelectionTieRecord", table)
      record.create!(id: 1, amount: 10, label: "excluded")
      record.create!(id: 2, amount: 10, label: "kept")
      record.create!(id: 3, amount: 9, label: "kept")

      filter = {
        type: "group", predicate: "and",
        filters: [{
          type: "group", predicate: "and",
            filters: [property_filter("label", "eq", "excluded")],
          negate: true,
          order: [
            {property: "amount", direction: "desc"},
            {property: "id", direction: "asc"}
          ], limit: 1
        }]
      }

      expect(Scry.filter_records_by(records: record, filter:).relation.pluck(:id)).to eq([2])
    end
  end

  it "rejects invalid selection modifier shapes" do
    with_temporary_table(
      "af_invalid_group_selection_modifiers",
      "id bigint PRIMARY KEY, amount bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::InvalidGroupSelectionRecord", table)
      record.create!(id: 1, amount: 1)
      invalid_filters = [
        {order: [{property: "amount", direction: "sideways"}]},
        {order: {property: "amount", direction: "asc"}},
        {limit: "one"},
        {limit: -1},
        {offset: "zero"},
        {offset: -1}
      ]

      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        invalid_filters.each do |modifiers|
          filter = {type: "group", predicate: "and", filters: [property_filter("amount", "gteq", 0)]}.merge(modifiers)
          expect { Scry.filter_records_by(records: record, filter:).relation }
            .to raise_error(Scry::FilterError), modifiers.inspect
        end
      end
    end
  end

  it "preserves a selected computed alias through candidate pagination" do
    user = create(:user)
    first = create(:email, address: "long@example.com")
    second = create(:email, address: "x@example.com")
    user.emails << [first, second]
    ranked = Email
      .select(:id, Arel::Nodes::NamedFunction.new("LENGTH", [Email.arel_table[:address]]).as("address_rank"))
      .order("address_rank DESC")
      .limit(1)

    filter = {
      type: "group",
      predicate: "and",
      filters: [{type: "association", association: "emails", predicate: "has_any", args: [ranked]}]
    }

    expect(Scry.filter_records_by(records: User.where(id: user.id), filter: filter).relation.pluck(:id))
      .to eq([user.id])
  end
end
