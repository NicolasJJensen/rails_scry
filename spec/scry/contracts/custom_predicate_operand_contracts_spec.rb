# frozen_string_literal: true

require "rails_helper"
require_relative "../interoperability/temporary_table_support"

RSpec.describe "custom predicate operand contracts", :interoperability do
  def custom_predicate_filter(type:, predicate:, expression: nil, value:)
    node = {type:, predicate:, args: [value]}
    if type == "computed"
      node[:expression] = expression
    else
      node[:property] = "value"
    end
    {type: "group", predicate: "and", filters: [node]}
  end

  it "passes the formatted Ruby operand to custom predicates for properties and computed expressions" do
    with_temporary_table("af_custom_operand_records", "id bigint PRIMARY KEY, value integer NOT NULL") do |table|
      record = temporary_model("CustomPredicateOperands::Record", table)
      record.create!(id: 1, value: 7)
      seen = []

      Scry.configuration.register_predicate(
        :custom_integer_equal, types: [:numerical], applies_to: %i[property computed], compounds: false,
        formatter: ->(operand) { Integer(operand) }
      ) do |attribute, operand|
        seen << operand
        attribute.eq(operand)
      end
      record.add_filter_permission(:property_predicates) do
        {value: [:custom_integer_equal]}
      end
      record.add_filter_permission(:predicates, list_type: :includelist) { [:custom_integer_equal] }

      property_filter = custom_predicate_filter(type: "property", predicate: "custom_integer_equal", value: "7")
      computed_filter = custom_predicate_filter(
        type: "computed", predicate: "custom_integer_equal", value: "7",
        expression: {property: "value"}
      )

      expect(Scry.filter_records_by(records: record, filter: property_filter).relation.ids).to eq([1])
      expect(Scry.filter_records_by(records: record, filter: computed_filter).relation.ids).to eq([1])
      expect(seen).to eq([7, 7])
      expect(seen).to all(be_a(Integer))
    end
  end
end
