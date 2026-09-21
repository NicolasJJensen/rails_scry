# frozen_string_literal: true

require "rails_helper"
require_relative "../interoperability/temporary_table_support"

RSpec.describe "computed filter expressions", :interoperability do
  def computed_filter(expression, predicate: "gteq", value: 0)
    {
      type: "group", predicate: "and",
      filters: [{type: "computed", expression:, predicate:, args: [value]}]
    }
  end

  it "filters on a subtract expression supplied in the filter hash" do
    with_temporary_table(
      "af_computed_invoices",
      "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, subtotal_cents bigint NOT NULL, discount_cents bigint NOT NULL"
    ) do |table|
      invoice = temporary_model("InteroperabilityTemporary::ComputedInvoice", table)
      invoice.create!(id: 1, tenant_id: 7, subtotal_cents: 12_000, discount_cents: 1_500)
      invoice.create!(id: 2, tenant_id: 7, subtotal_cents: 10_000, discount_cents: 500)
      invoice.create!(id: 3, tenant_id: 7, subtotal_cents: 9_000, discount_cents: 100)

      filter = computed_filter(
        {operator: "subtract", operands: [{property: "subtotal_cents"}, {property: "discount_cents"}]},
        predicate: "gteq", value: 10_000
      )

      expect(Scry.filter_records_by(records: invoice, filter: filter).relation.pluck(:id)).to eq([1])
    end
  end

  it "rejects an expression leaf that is not an allowed property" do
    with_temporary_table(
      "af_computed_permission_invoices",
      "id bigint PRIMARY KEY, subtotal_cents bigint NOT NULL, discount_cents bigint NOT NULL"
    ) do |table|
      invoice = temporary_model("InteroperabilityTemporary::ComputedPermissionInvoice", table)
      invoice.add_filter_permission(:properties, list_type: :whitelist) { [:subtotal_cents] }

      filter = computed_filter(
        {operator: "subtract", operands: [{property: "subtotal_cents"}, {property: "discount_cents"}]},
        predicate: "gteq", value: 1
      )

      expect {
        Scry.configuration.with_temporary_settings do |config|
          config.invalid_filter_policy = :raise
          Scry.filter_records_by(records: invoice, filter: filter).relation
        end
      }.to raise_error(Scry::FilterError, /invalid property|permission/)
    end
  end

  it "supports the initial numeric expression operators" do
    with_temporary_table(
      "af_computed_numeric_ops",
      "id bigint PRIMARY KEY, left_value bigint NOT NULL, right_value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedNumericRecord", table)
      record.create!(id: 1, left_value: 20, right_value: 5)
      record.create!(id: 2, left_value: 8, right_value: 4)
      record.create!(id: 3, left_value: 7, right_value: 2)
      record.create!(id: 4, left_value: 7, right_value: 0)

      expectations = {
        "add" => 25,
        "subtract" => 15,
        "multiply" => 100,
        "divide" => 4
      }
      expectations.each do |operator, expected|
        filter = computed_filter(
          {operator:, operands: [{property: "left_value"}, {property: "right_value"}]},
          predicate: "eq", value: expected
        )
        expect(Scry.filter_records_by(records: record, filter:).relation.ids)
          .to eq([1]), "expected #{operator} to evaluate to #{expected}"
      end
      expect(Scry.filter_records_by(
        records: record, filter: computed_filter(
          {operator: "divide", operands: [{property: "left_value"}, {property: "right_value"}]},
          predicate: "eq", value: 3.5
        )
      ).relation.ids).to eq([3])
      expect(Scry.filter_records_by(
        records: record, filter: computed_filter(
          {operator: "divide", operands: [{property: "left_value"}, {property: "right_value"}]},
          predicate: "gteq", value: 1
        )
      ).relation.ids).to eq([1, 2, 3])

      nested = {
        operator: "multiply",
        operands: [
          {operator: "subtract", operands: [{property: "left_value"}, {literal: 1}]},
          {literal: 2}
        ]
      }
      expect(Scry.filter_records_by(
        records: record, filter: computed_filter(nested, predicate: "eq", value: 38)
      ).relation.ids).to eq([1])
    end
  end

  it "accepts the JSON representation of nested expression keys and literals" do
    with_temporary_table(
      "af_computed_json_expression",
      "id bigint PRIMARY KEY, left_value bigint NOT NULL, right_value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedJsonRecord", table)
      record.create!(id: 1, left_value: 20, right_value: 5)
      record.create!(id: 2, left_value: 8, right_value: 4)
      expression = {
        operator: "multiply",
        operands: [
          {operator: "subtract", operands: [{property: "left_value"}, {literal: 1}]},
          {literal: 2}
        ]
      }
      json_filter = JSON.parse(JSON.generate(computed_filter(expression, predicate: "eq", value: 38)))

      expect(Scry.filter_records_by(records: record, filter: json_filter).relation.ids).to eq([1])
    end
  end

  it "preserves fractional division when the numerator is fractional" do
    with_temporary_table(
      "af_computed_fractional_division",
      "id bigint PRIMARY KEY, left_value numeric NOT NULL, right_value numeric NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedFractionalRecord", table)
      record.create!(id: 1, left_value: 7.5, right_value: 2)
      filter = computed_filter(
        {operator: "divide", operands: [{property: "left_value"}, {property: "right_value"}]},
        predicate: "eq", value: 3.75
      )

      expect(Scry.filter_records_by(records: record, filter:).relation.ids).to eq([1])
    end
  end

  it "evaluates computed predicates against a derived relation source" do
    with_temporary_table(
      "af_computed_derived_source",
      "id bigint PRIMARY KEY, amount bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedDerivedSource", table)
      first = record.create!(id: 1, amount: 7)
      record.create!(id: 2, amount: 2)
      arel_table = record.arel_table
      derived = arel_table.project(
        arel_table[:id],
        (arel_table[:amount] * 2).as("amount")
      ).as("derived_records")
      records = record.select(:id, :amount).from(derived)
      filter = computed_filter(
        {
          operator: "multiply",
          operands: [
            {operator: "add", operands: [{property: "amount"}, {literal: 1}]},
            {literal: 2}
          ]
        },
        predicate: "eq", value: 30
      )

      expect(records.pluck(:amount)).to contain_exactly(14, 4)
      expect(Scry.filter_records_by(records:, filter:).relation.ids).to eq([first.id])
    end
  end

  it "preserves integer division precision on SQLite" do
    skip unless ActiveRecord::Base.connection.adapter_name.downcase == "sqlite"

    with_temporary_table(
      "af_computed_integer_division",
      "id bigint PRIMARY KEY, left_value bigint NOT NULL, right_value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedIntegerDivision", table)
      record.create!(id: 1, left_value: 7, right_value: 2)
      filter = computed_filter(
        {operator: "divide", operands: [{property: "left_value"}, {property: "right_value"}]},
        predicate: "eq", value: 3.5
      )

      expect(Scry.filter_records_by(records: record, filter:).relation.ids).to eq([1])
    end
  end

  it "supports compound predicates for computed expressions" do
    with_temporary_table(
      "af_computed_compound",
      "id bigint PRIMARY KEY, value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedCompound", table)
      record.create!(id: 1, value: 7)
      record.create!(id: 2, value: 9)
      filter = computed_filter(
        {operator: "add", operands: [{property: "value"}, {literal: 0}]},
        predicate: "eq_any", value: [7, 8]
      )

      expect(Scry.filter_records_by(records: record, filter:).relation.ids).to eq([1])
    end
  end

  it "formats each computed compound operand independently" do
    with_temporary_table(
      "af_computed_compound_formatter",
      "id bigint PRIMARY KEY, value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedCompoundFormatter", table)
      record.create!(id: 1, value: 7)
      record.create!(id: 2, value: 9)
      Scry.configuration.register_predicate(
        :computed_integer_eq, types: [:numerical], applies_to: [:computed], compounds: true, arel_predicate: :eq,
        formatter: ->(value) { Integer(value) }
      )
      filter = computed_filter(
        {operator: "add", operands: [{property: "value"}, {literal: 0}]},
        predicate: "computed_integer_eq_any", value: ["7", "8"]
      )

      expect(Scry.filter_records_by(records: record, filter:).relation.ids).to eq([1])
    end
  end

  it "rejects an omitted value for a computed nonzero-arity predicate" do
    with_temporary_table(
      "af_computed_missing_value",
      "id bigint PRIMARY KEY, value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedMissingValue", table)
      filter = computed_filter(
        {property: "value"}, predicate: "gteq", value: :__omitted__
      ).tap { |node| node[:filters].first.delete(:args) }

      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        expect { Scry.filter_records_by(records: record, filter:).relation }
        .to raise_error(Scry::FilterError, /expects 1 argument/)
      end
    end
  end

  it "does not authorize a literal-only computed predicate through empty property leaves" do
    with_temporary_table(
      "af_computed_literal_permission",
      "id bigint PRIMARY KEY, value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedLiteralPermission", table)
      record.create!(id: 1, value: 1)
      called = false
      Scry.configuration.register_predicate(:literal_secret, types: [:numerical], compounds: false) do |attr, value|
        called = true
        attr.eq(value)
      end
      record.add_filter_permission(:predicates, list_type: :excludelist) { [:literal_secret] }
      expect(record.scry_permissions.allowed_predicates(nil)).not_to include(:literal_secret)

      filter = computed_filter({literal: 1}, predicate: "literal_secret", value: 1)
      result = Scry.filter_records_by(records: record, filter:)

      expect(called).to be(false)
      expect(result.diagnostics.map(&:category)).to include(:permission_denied)
      expect(result.diagnostics.map(&:code)).to include(:predicate_denied)
    end
  end

  it "rejects malformed or unsafe expression nodes before query execution" do
    with_temporary_table(
      "af_computed_invalid_nodes",
      "id bigint PRIMARY KEY, value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedInvalidRecord", table)
      record.create!(id: 1, value: 1)
      invalid_expressions = [
        {operator: "unknown", operands: [{property: "value"}, {literal: 1}]},
        {operator: "add", operands: [{property: "value"}]},
        {operator: "add", operands: [{property: "value"}, {literal: Float::NAN}]},
        {operator: "add", operands: [{property: "value"}, {raw_sql: "value + 1"}]},
        {operator: "divide", operands: [{property: "value"}, {literal: 0}]}
      ]

      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise
        invalid_expressions.each do |expression|
          expect {
            Scry.filter_records_by(records: record, filter: computed_filter(expression)).relation
          }.to raise_error(Scry::FilterError), expression.inspect
        end
      end
    end
  end

  it "does not let a property predicate bypass expression permissions by adding zero" do
    with_temporary_table(
      "af_computed_permission_bypass",
      "id bigint PRIMARY KEY, allowed_value bigint NOT NULL, secret_value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedPermissionBypassRecord", table)
      record.add_filter_permission(:properties, list_type: :whitelist) { [:allowed_value] }
      record.create!(id: 1, allowed_value: 1, secret_value: 10)

      expression = {
        operator: "add",
        operands: [{property: "secret_value"}, {literal: 0}]
      }
      Scry.configuration.with_temporary_settings do |config|
          config.invalid_filter_policy = :raise
        expect {
          Scry.filter_records_by(records: record, filter: computed_filter(expression)).relation
        }.to raise_error(Scry::FilterError, /property|permission/)
      end
    end
  end

  it "preserves predicate callback failure semantics for computed values" do
    with_temporary_table(
      "af_computed_callback_failure",
      "id bigint PRIMARY KEY, left_value bigint NOT NULL, right_value bigint NOT NULL"
    ) do |table|
      record = temporary_model("InteroperabilityTemporary::ComputedCallbackRecord", table)
      record.create!(id: 1, left_value: 2, right_value: 1)
      Scry.configuration.register_predicate(
        :computed_callback_failure, types: [:numerical], applies_to: [:computed], compounds: false
      ) { |_attribute, _value| raise "computed predicate callback failed" }
      record.add_filter_permission(:predicates, list_type: :includelist) { [:computed_callback_failure] }

      filter = computed_filter(
        {operator: "subtract", operands: [{property: "left_value"}, {property: "right_value"}]},
        predicate: "computed_callback_failure", value: 1
      )
      expect { Scry.filter_records_by(records: record, filter:).relation }
        .to raise_error(RuntimeError, "computed predicate callback failed")
    end
  end

  it "enforces input node and byte limits before compiling expressions" do
    filter = {type: "computed", expression: {operator: "add", operands: [{literal: 1}, {literal: 2}]}}
    Scry.configuration.with_temporary_settings do |config|
      config.max_filter_nodes = 3
      expect { Scry::Input.normalize(filter) }
        .to raise_error(Scry::FilterError, /max_filter_nodes/)
      config.max_filter_nodes = 1_000
      config.max_filter_bytes = 8
      expect { Scry::Input.normalize(filter) }
        .to raise_error(Scry::FilterError, /max_filter_bytes/)
    end
  end
end
