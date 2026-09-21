# frozen_string_literal: true

require "rails_helper"

RSpec.describe "predicate signature contracts" do
  around do |example|
    Scry.configuration.with_temporary_settings { |config| example.run }
  end

  def apply(predicate, args)
    Scry.filter_records_by(
      records: User,
      filter: { type: :property, property: :first_name, predicate:, args: }
    )
  end

  it "infers required and optional positional arguments from a predicate block" do
    Scry.configuration.register_predicate(:surrounded,
      types: [:textual], compounds: false) do |attribute, prefix, suffix = ""|
      attribute.eq("#{prefix}Ada#{suffix}")
    end

    create(:user, first_name: "[Ada]")
    definition = Scry.configuration.predicate_registry.by_name(:surrounded)

    expect(definition).to include(
      parameters: [
        { name: :prefix, kind: :required },
        { name: :suffix, kind: :optional }
      ],
      arguments: {min: 1, max: 2}
    )
    expect(apply(:surrounded, ["["]).relation).to be_empty
    expect(apply(:surrounded, ["[", "]"]).relation.map(&:first_name)).to eq(["[Ada]"])
  end

  it "infers zero arguments from a one-argument predicate block" do
    Scry.configuration.register_predicate(:named_ada,
      types: [:textual], compounds: false) do |attribute|
      attribute.eq("Ada")
    end

    create(:user, first_name: "Ada")
    definition = Scry.configuration.predicate_registry.by_name(:named_ada)

    expect(definition).to include(parameters: [], arguments: {min: 0, max: 0})
    expect(apply(:named_ada, []).relation.map(&:first_name)).to eq(["Ada"])
  end

  it "infers a rest argument and keeps a collection as one explicit argument" do
    received = []
    callback = ->(attribute, first, *rest) do
      received << [first, rest]
      attribute.in([first, *rest])
    end
    Scry.configuration.register_predicate(:one_of_names,
      types: [:textual], compounds: false, &callback)

    first = create(:user, first_name: "Ada")
    second = create(:user, first_name: "Grace")
    definition = Scry.configuration.predicate_registry.by_name(:one_of_names)

    expect(definition).to include(
      parameters: [
        { name: :first, kind: :required },
        { name: :rest, kind: :rest }
      ],
      arguments: {min: 1, max: nil}
    )
    apply(:one_of_names, [[first.first_name, second.first_name]])
    expect(received).to eq([[[first.first_name, second.first_name], []]])
    expect(apply(:one_of_names, [first.first_name, second.first_name]).relation.ids)
      .to contain_exactly(first.id, second.id)
  end

  it "uses the same inferred signature for a registered Arel predicate method" do
    Arel::Predications.module_eval do
      define_method(:equals_with_suffix) do |prefix, suffix = ""|
        eq("#{prefix}Ada#{suffix}")
      end
    end unless Arel::Predications.method_defined?(:equals_with_suffix)

    Scry.configuration.register_predicate(:equals_with_suffix,
      types: [:textual], compounds: false, arel_predicate: :equals_with_suffix)
    create(:user, first_name: "<Ada>")

    definition = Scry.configuration.predicate_registry.by_name(:equals_with_suffix)
    expect(definition).to include(arguments: {min: 1, max: 2})
    expect(apply(:equals_with_suffix, ["<", ">"]).relation.map(&:first_name)).to eq(["<Ada>"])
  end

  it "uses an Arel method optional default when args is omitted" do
    Arel::Predications.module_eval do
      define_method(:matches_named_default) do |name = "Ada"|
        matches("%#{name}%")
      end
    end unless Arel::Predications.method_defined?(:matches_named_default)

    Scry.configuration.register_predicate(:matches_named_default,
      types: [:textual], compounds: false, arel_predicate: :matches_named_default)
    create(:user, first_name: "Ada Lovelace")

    definition = Scry.configuration.predicate_registry.by_name(:matches_named_default)
    expect(definition).to include(
      parameters: [{ name: :name, kind: :optional }], arguments: {min: 0, max: 1}
    )
    expect(apply(:matches_named_default, []).relation.map(&:first_name)).to eq(["Ada Lovelace"])
  end

  it "preserves optional boolean controls for an Arel predicate method" do
    Arel::Predications.module_eval do
      define_method(:equals_with_toggle) do |value, exact = false|
        exact ? eq(value) : matches("%#{value}%")
      end
    end unless Arel::Predications.method_defined?(:equals_with_toggle)

    Scry.configuration.register_predicate(:equals_with_toggle,
      types: [:textual], compounds: false, arel_predicate: :equals_with_toggle)
    exact = create(:user, first_name: "Ada")
    partial = create(:user, first_name: "Ada Lovelace")

    expect(apply(:equals_with_toggle, ["Ada"]).relation.ids).to contain_exactly(exact.id, partial.id)
    expect(apply(:equals_with_toggle, ["Ada", true]).relation.ids).to eq([exact.id])
    expect(apply(:equals_with_toggle, ["Ada", false]).relation.ids).to contain_exactly(exact.id, partial.id)
  end

  it "infers required, optional, and rest parameters without flattening a nested collection" do
    received = []
    callback = ->(attribute, first, second, separator = ":", *rest) do
      received << [first, second, separator, rest]
      attribute.eq(first)
    end
    Scry.configuration.register_predicate(:assembled_name,
      types: [:textual], compounds: false, &callback)

    definition = Scry.configuration.predicate_registry.by_name(:assembled_name)
    expect(definition).to include(
      parameters: [
        { name: :first, kind: :required },
        { name: :second, kind: :required },
        { name: :separator, kind: :optional },
        { name: :rest, kind: :rest }
      ],
      arguments: {min: 2, max: nil}
    )

    apply(:assembled_name, ["Ada", "Lovelace", ["kept", "together"]])
    expect(received).to eq([["Ada", "Lovelace", ["kept", "together"], []]])
  end

  it "derives the built-in between metadata from its two positional arguments" do
    record = create(:user, date_of_birth: Date.new(1990, 1, 1))
    definition = Scry.configuration.predicate_registry.by_name(:between)

    expect(definition).to include(
      parameters: [
        { name: :lower, kind: :required },
        { name: :upper, kind: :required }
      ],
      arguments: {min: 2, max: 2}
    )
    result = Scry.filter_records_by(
      records: User.where(id: record.id),
      filter: {
        type: :property, property: :date_of_birth, predicate: :between,
        args: [Date.new(1989, 1, 1), Date.new(1991, 1, 1)]
      }
    )
    expect(result.relation.count).to eq(1)
  end

  it "preserves non-lambda required parameters when keyword Proc reflection is unavailable" do
    callback = proc { |attribute, required, optional = ""| attribute.eq("#{required}#{optional}") }
    original_parameters = callback.method(:parameters)
    callback.define_singleton_method(:parameters) do |*arguments, **keywords|
      raise ArgumentError, "keyword reflection unavailable" if keywords.any?

      original_parameters.call(*arguments)
    end

    signature = Scry.configuration.__send__(:predicate_signature, callback, receiver: 1)

    expect(signature).to eq(
      parameters: [
        {name: :required, kind: :required},
        {name: :optional, kind: :optional}
      ],
      arguments: {min: 1, max: 2}
    )
  end

  it "rejects the removed params descriptor" do
    expect {
      Scry.configuration.register_predicate(:legacy_params,
        types: [:textual], params: 1, compounds: false, arel_predicate: :eq)
    }.to raise_error(ArgumentError, /params/i)
  end
end
