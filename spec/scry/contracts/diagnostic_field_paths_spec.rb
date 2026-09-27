# frozen_string_literal: true

require "rails_helper"

RSpec.describe "diagnostic field paths" do
  def group(*filters, **options)
    {type: :group, predicate: :and, filters:, **options}
  end

  def property(name: :first_name, predicate: :eq, args: ["Ada"], **options)
    {type: :property, property: name, predicate:, args:, **options}
  end

  def diagnostic_path(filter, records: User)
    Scry.filter_records_by(records:, filter:).diagnostics.first.path
  end

  around do |example|
    Scry.configuration.with_temporary_settings do |config|
      config.invalid_filter_policy = :skip
      config.callback_error_policy = :match_none
      example.run
    end
  end

  describe "filter fields" do
    it "locates a missing or denied property at property" do
      expect(diagnostic_path(group(property(name: :missing_name))))
        .to eq([:filters, 0, :property])
      expect(diagnostic_path(group(property(name: "not-a-property"))))
        .to eq([:filters, 0, :property])
      expect(diagnostic_path(group({type: :property, predicate: :eq, args: ["Ada"]})))
        .to eq([:filters, 0, :property])
    end

    it "locates predicate failures at predicate" do
      expect(diagnostic_path(group(property(predicate: "not-a-predicate"))))
        .to eq([:filters, 0, :predicate])
      expect(diagnostic_path(group(property(predicate: "bad-predicate"))))
        .to eq([:filters, 0, :predicate])
    end

    it "locates malformed arity and operand shape at args and its index" do
      expect(diagnostic_path(group(property(args: "Ada"))))
        .to eq([:filters, 0, :args])
      expect(diagnostic_path(group(property(name: :id, predicate: :gt, args: [["Ada"]]))))
        .to eq([:filters, 0, :args, 0])
    end

    it "locates missing predicate at predicate" do
      expect(diagnostic_path(group({type: :property, property: :first_name, args: ["Ada"]})))
        .to eq([:filters, 0, :predicate])
    end

    it "locates an unknown filter type at its type field" do
      expect(diagnostic_path(group({type: :unknown_filter}))).to eq([:filters, 0, :type])
    end

    it "preserves the field path through nested association scoping" do
      filter = group(
        type: :association,
        association: :users,
        predicate: :has_any,
        args: [[1]],
        scoping: group(property(name: :missing_name))
      )

      expect(diagnostic_path(group(filter), records: Organisation))
        .to eq([:filters, 0, :scoping, :filters, 0, :property])
    end
  end

  describe "association and aggregate fields" do
    it "locates invalid association input at association" do
      filter = group(type: :association, association: :missing, predicate: :has_any, args: [[1]])
      expect(diagnostic_path(group(filter))).to eq([:filters, 0, :association])
    end

    it "locates malformed native membership operands at their argument" do
      filter = group(type: :association, association: :organisation, predicate: :has_any, args: [["not_an_integer"]])

      expect(diagnostic_path(group(filter), records: User)).to eq([:filters, 0, :args, 0])
    end

    it "locates aggregate names and properties at their DSL fields" do
      unknown = group(type: :aggregate, association: :emails, aggregate: :missing, predicate: :gteq, args: [1])
      invalid_property = group(type: :aggregate, association: :emails, aggregate: :sum, property: :missing, predicate: :gteq, args: [1])

      expect(diagnostic_path(group(unknown), records: User)).to eq([:filters, 0, :aggregate])
      expect(diagnostic_path(group(invalid_property), records: User)).to eq([:filters, 0, :property])
    end
  end

  describe "partial association scopes" do
    %i[association aggregate].each do |kind|
      %i[skip match_none raise].each do |policy|
        it "preserves scoped field errors for #{kind} under #{policy}" do
          organisation = create(:organisation)
          user = create(:user, organisation:, first_name: "Scoped match")
          node = {
            type: kind, association: :users,
            predicate: kind == :association ? :has_any : :gteq,
            args: kind == :association ? [[user.id]] : [1],
            scoping: group(property(args: [user.first_name]), property(name: :missing_name))
          }
          filter = group(node)
          records = Organisation.where(id: organisation.id)
          path = [:filters, 0, :scoping, :filters, 1, :property]
          Scry.configuration.invalid_filter_policy = policy

          if policy == :raise
            expect { Scry.filter_records_by(records:, filter:) }.to raise_error(Scry::FilterError) { |error|
              expect(error.result.diagnostics.map(&:path)).to eq([path])
            }
          else
            result = Scry.filter_records_by(records:, filter:)
            expect(result.diagnostics.map(&:path)).to eq([path])
            if policy == :skip
              expect(result).to be_partial
              expect(result.relation.ids).to eq([organisation.id])
            else
              expect(result).to be_failed
              expect(result.relation).to be_empty
            end
          end
        end
      end
    end
  end

  describe "group selection fields" do
    let(:valid_child) { property }

    it "locates order direction, property, and expression failures" do
      bad_direction = group(valid_child, order: [{property: :first_name, direction: :sideways}])
      bad_property = group(valid_child, order: [{property: :missing_name, direction: :asc}])
      bad_expression = group(valid_child, order: [{expression: {property: :missing_name}, direction: :asc}])

      expect(diagnostic_path(bad_direction)).to eq([:order, 0, :direction])
      expect(diagnostic_path(bad_property)).to eq([:order, 0, :property])
      expect(diagnostic_path(bad_expression)).to eq([:order, 0, :expression, :property])
    end

    it "locates invalid limit and offset values at their fields" do
      expect(diagnostic_path(group(valid_child, limit: -1))).to eq([:limit])
      expect(diagnostic_path(group(valid_child, offset: "one"))).to eq([:offset])
    end

    it "preserves a child property path when group selection also fails" do
      filter = group(
        valid_child,
        property(name: :missing_name),
        order: [{property: :first_name, direction: :sideways}]
      )
      result = Scry.filter_records_by(records: User, filter:)

      expect(result.diagnostics.map(&:path)).to contain_exactly(
        [:filters, 1, :property],
        [:order, 0, :direction]
      )
    end
  end

  describe "computed expressions" do
    it "locates a recursive expression leaf" do
      expression = {
        operator: :add,
        operands: [
          {property: :id},
          {operator: :multiply, operands: [{property: :missing_name}, {literal: 2}]}
        ]
      }
      filter = group(type: :computed, expression:, predicate: :gt, args: [0])

      expect(diagnostic_path(group(filter))).to eq([:filters, 0, :expression, :operands, 1, :operands, 0, :property])
    end

    it "locates expression operators, literals, and operand shape" do
      invalid_operator = group(type: :computed, expression: {operator: :unknown}, predicate: :gt, args: [0])
      invalid_literal = group(type: :computed, expression: {literal: "not_numeric"}, predicate: :gt, args: [0])
      invalid_arity = group(type: :computed, expression: {operator: :add, operands: [{property: :id}]}, predicate: :gt, args: [0])

      expect(diagnostic_path(group(invalid_operator))).to eq([:filters, 0, :expression, :operator])
      expect(diagnostic_path(group(invalid_literal))).to eq([:filters, 0, :expression, :literal])
      expect(diagnostic_path(group(invalid_arity))).to eq([:filters, 0, :expression, :operands])
    end
  end

  describe "callback origins" do
    it "locates a failure in the second positional argument" do
      Scry.configuration.register_predicate(
        :diagnostic_second_argument,
        types: [:numerical], applies_to: [:property], compounds: false,
        validator: ->(value) { raise ArgumentError, "second argument failed" if value == "bad"; value }
      ) { |attribute, first, second| attribute.between(first, second) }

      filter = group(property(name: :id, predicate: :diagnostic_second_argument, args: [1, "bad"]))

      expect(diagnostic_path(filter)).to eq([:filters, 0, :args, 1])
    end

    it "reports validator and formatter failures at the operand" do
      Scry.configuration.register_predicate(
        :diagnostic_validator_failure,
        types: [:textual], applies_to: [:property], compounds: false,
        validator: ->(_value) { raise ArgumentError, "validator failed" }
      ) { |attribute, _value| attribute.eq("Ada") }
      Scry.configuration.register_predicate(
        :diagnostic_formatter_failure,
        types: [:textual], applies_to: [:property], compounds: false,
        formatter: ->(_value) { raise ArgumentError, "formatter failed" }
      ) { |attribute, _value| attribute.eq("Ada") }

      expect(diagnostic_path(group(property(predicate: :diagnostic_validator_failure))))
        .to eq([:filters, 0, :args, 0])
      expect(diagnostic_path(group(property(predicate: :diagnostic_formatter_failure))))
        .to eq([:filters, 0, :args, 0])
    end

    it "reports value transform failures at the operand" do
      original = User.scry_permissions.deep_dup(klass: User)
      User.add_filter_transform(:first_name, on: :value) { raise ArgumentError, "transform failed" }

      expect(diagnostic_path(group(property))).to eq([:filters, 0, :args, 0])
    ensure
      User.scry_permissions = original if original
      Scry.clear_thread_caches!
    end

    it "reports attribute and value-node transform failures at the operand" do
      original = User.scry_permissions.deep_dup(klass: User)
      User.add_filter_transform(:first_name, on: :attribute) { raise ArgumentError, "attribute failed" }
      User.add_filter_transform(:first_name, on: :value_node) { raise ArgumentError, "value node failed" }

      expect(diagnostic_path(group(property))).to eq([:filters, 0, :args, 0])
    ensure
      User.scry_permissions = original if original
      Scry.clear_thread_caches!
    end

    it "reports custom predicate failures at predicate" do
      Scry.configuration.register_predicate(
        :diagnostic_custom_failure,
        types: [:textual], applies_to: [:property], compounds: false
      ) { |_attribute, _value| raise ArgumentError, "predicate failed" }

      expect(diagnostic_path(group(property(predicate: :diagnostic_custom_failure))))
        .to eq([:filters, 0, :predicate])
    end

    it "reports aggregate builder failures at aggregate" do
      Scry.configuration.register_aggregate(:diagnostic_builder_failure, types: [:all], property: false) do |_attribute, _distinct|
        raise ArgumentError, "builder failed"
      end
      filter = {type: :aggregate, association: :emails, aggregate: :diagnostic_builder_failure, predicate: :gteq, args: [1]}

      expect(diagnostic_path(group(filter), records: User)).to eq([:filters, 0, :aggregate])
    end
  end

  describe "public result policies" do
    let(:filter) { group(property(name: :missing_name)) }

    it "keeps the same field path for skip, raise, and match_none" do
      Scry.configuration.invalid_filter_policy = :skip
      skipped = Scry.filter_records_by(records: User, filter:)

      Scry.configuration.invalid_filter_policy = :match_none
      matched_none = Scry.filter_records_by(records: User, filter:)

      Scry.configuration.invalid_filter_policy = :raise
      expect { Scry.filter_records_by(records: User, filter:) }.to raise_error(Scry::FilterError) { |error|
        expect(error.result.diagnostics.first.path).to eq([:filters, 0, :property])
      }

      expect(skipped.diagnostics.first.path).to eq([:filters, 0, :property])
      expect(matched_none.diagnostics.first.path).to eq([:filters, 0, :property])
      expect(matched_none.relation).to be_empty
    end

    it "keeps paths immutable and JSON serializable" do
      diagnostic = Scry.filter_records_by(records: User, filter:).diagnostics.first

      expect(diagnostic.path).to be_frozen
      expect(diagnostic.to_h[:path]).to eq([:filters, 0, :property])
      expect { JSON.generate(diagnostic.to_h) }.not_to raise_error
    end
  end

  describe "custom filter failures" do
    it "allows a custom filter to identify its value field at root and nested paths" do
      custom = Class.new(Scry::Filters::Base) do
        def apply
          failure("custom value failed", path: field_path(:value), code: :custom_value)
        end
      end
      Scry.configuration.register_filter(:diagnostic_custom_filter, custom)

      expect(diagnostic_path({type: :diagnostic_custom_filter})).to eq([:value])
      expect(diagnostic_path(group({type: :diagnostic_custom_filter}))).to eq([:filters, 0, :value])
    end
  end
end
