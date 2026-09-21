# frozen_string_literal: true

require "rails_helper"

RSpec.describe "filter argument DSL" do
  def filter_records(filter)
    Scry.filter_records_by(records: User, filter:, context: nil)
  end

  def group(*filters)
    {type: "group", predicate: "and", filters:}
  end

  it "uses filters for groups and a one-element args list for scalar operands" do
    user = create(:user, first_name: "Args scalar")

    result = filter_records(group(
      {type: "property", property: "first_name", predicate: "eq", args: ["Args scalar"]}
    ))

    expect(result).to be_success
    expect(result.relation).to contain_exactly(user)
  end

  it "keeps a collection as one argument for collection predicates" do
    first = create(:user, first_name: "Args collection one")
    second = create(:user, first_name: "Args collection two")
    create(:user, first_name: "Args collection other")

    result = filter_records(group(
      {type: "property", property: "first_name", predicate: "eq_any", args: [[first.first_name, second.first_name]]}
    ))

    expect(result).to be_success
    expect(result.relation).to contain_exactly(first, second)
  end

  it "passes two positional arguments to the built-in between predicate" do
    lower = create(:user, first_name: "Args between lower")
    middle = create(:user, first_name: "Args between middle")
    upper = create(:user, first_name: "Args between upper")

    result = filter_records(group(
      {type: "property", property: "id", predicate: "between", args: [lower.id, upper.id]}
    ))

    expect(result).to be_success
    expect(result.relation).to contain_exactly(lower, middle, upper)
  end

  it "accepts omitted arguments for zero-argument predicates" do
    expected = create(:user)

    result = filter_records(group(
      {type: "property", property: "id", predicate: "not_eq_nil"}
    ))

    expect(result).to be_success
    expect(result.relation).to include(expected)
  end

  it "rejects legacy value keys" do
    result = filter_records(
      type: "group", predicate: "and", value: [
        {type: "property", property: "first_name", predicate: "eq", args: ["legacy"]}
      ]
    )

    expect(result).to be_failed
    expect(result.diagnostics.map(&:code)).to include(:invalid_group_filters)
  end

  it "rejects non-array args and wrong argument cardinality" do
    malformed = filter_records(group(
      {type: "property", property: "first_name", predicate: "eq", args: "not an array"}
    ))
    missing = filter_records(group(
      {type: "property", property: "first_name", predicate: "eq", args: []}
    ))

    expect(malformed).to be_failed
    expect(malformed.diagnostics.map(&:code)).to include(:invalid_filter_args)
    expect(missing).to be_failed
    expect(missing.diagnostics.map(&:code)).to include(:invalid_filter_args)
  end
end
