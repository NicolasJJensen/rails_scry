# frozen_string_literal: true

require "rails_helper"

RSpec.describe "custom filter extension API" do
  around do |example|
    Scry.configuration.with_temporary_settings { |config| example.run }
  end

  it "calls apply at the root with depth zero and exposes protected extension inputs" do
    filter_class = Class.new(Scry::Filters::Base) do
      attr_reader :received_depth

      def initialize(model:, filter:, context:, depth:)
        super
        @received_depth = depth
      end

      def apply
        raise "missing filter reader" unless filter[:type] == :inspect_extension
        raise "missing context reader" unless context == :viewer
        raise "missing model reader" unless model == User
        raise "missing scope reader" unless scope.is_a?(ActiveRecord::Relation)
        raise "missing depth reader" unless depth.zero?

        success(source_relation.where(source_attribute(:first_name).eq("Ada")))
      end
    end
    stub_const("FilterExtensionApiContract::InspectExtension", filter_class)
    Scry.configuration.register_filter(:inspect_extension, filter_class)
    create(:user, first_name: "Ada")

    result = Scry.filter_records_by(
      records: User,
      filter: { type: :inspect_extension },
      context: :viewer
    )

    expect(result).to be_success
    expect(result.relation.map(&:first_name)).to eq(["Ada"])
  end

  it "rejects list_type supplied through the generic model permission API" do
    expect {
      User.add_filter_permission(:model, list_type: :whitelist) { |_context| true }
    }.to raise_error(ArgumentError, /model.*list_type/i)
  end

  it "normalizes a JSON nested definition without changing JSON predicate arguments" do
    nested_filter = Class.new(Scry::Filters::Base) do
      def apply
        raise "nested DSL keys were not normalized" unless filter[:property] == "first_name"
        raise "JSON predicate arguments were changed" unless filter[:args] == [{ "operator" => "eq" }]

        success(scope)
      end
    end
    wrapper_filter = Class.new(Scry::Filters::Base) do
      def apply
        compile_nested_filter(filter[:child])
      end
    end
    stub_const("FilterExtensionApiContract::NestedFilter", nested_filter)
    stub_const("FilterExtensionApiContract::WrapperFilter", wrapper_filter)
    Scry.configuration.register_filter(:nested_definition, nested_filter)
    Scry.configuration.register_filter(:wrapper_definition, wrapper_filter)

    result = Scry.filter_records_by(
      records: User,
      filter: {
        "type" => "wrapper_definition",
        "child" => {
          "type" => "nested_definition",
          "property" => "first_name",
          "args" => [{ "operator" => "eq" }]
        }
      }
    )

    expect(result).to be_success
  end
end
