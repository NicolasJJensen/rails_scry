require "rails_helper"

RSpec.describe "predicate applicability" do
  around do |example|
    Scry.configuration.with_temporary_settings { example.run }
  end

  def group(node)
    {type: "group", predicate: "and", filters: [node]}
  end

  it "keeps custom predicates on properties by default and rejects computed and aggregate use" do
    user = create(:user, first_name: "Ada", emails_count: 0)
    user.emails << create(:email, address: "one@example.test")
    Scry.configuration.register_predicate(:custom_number, types: [:numerical], compounds: false) do |attribute, value|
      attribute.eq(value)
    end
    property = group(type: "property", property: "id", predicate: "custom_number", args: [user.id])
    computed = group(type: "computed", expression: {property: "id"}, predicate: "custom_number", args: [user.id])
    aggregate = group(type: "aggregate", association: "emails", aggregate: "count", predicate: "custom_number", args: [1])

    expect(Scry.filter_records_by(records: User.where(id: user.id), filter: property).relation.ids).to eq([user.id])
    expect(Scry.filter_records_by(records: User.where(id: user.id), filter: computed).diagnostics.map(&:code)).to include(:predicate_denied)
    expect(Scry.filter_records_by(records: User.where(id: user.id), filter: aggregate).diagnostics.map(&:code)).to include(:aggregate_denied)
  end

  it "allows an explicitly opted-in computed predicate and rejects incompatible string leaves" do
    record = create(:user, first_name: "Ada")
    Scry.configuration.register_predicate(:computed_number, types: [:numerical], applies_to: [:computed], compounds: false) do |attribute, value|
      attribute.eq(value)
    end
    allowed = group(type: "computed", expression: {operator: "add", operands: [{property: "id"}, {literal: 0}]}, predicate: "computed_number", args: [record.id])
    incompatible = group(type: "computed", expression: {property: "first_name"}, predicate: "computed_number", args: [record.id])

    expect(Scry.filter_records_by(records: User.where(id: record.id), filter: allowed).relation.ids).to eq([record.id])
    expect(Scry.filter_records_by(records: User.where(id: record.id), filter: incompatible).diagnostics.map(&:code)).to include(:predicate_denied)
  end

  it "exposes declared types and preserves computed applicability in discovery metadata" do
    Scry.configuration.register_predicate(
      :computed_number, types: [:numerical], applies_to: [:computed], compounds: false
    ) do |attribute, value|
      attribute.eq(value)
    end

    metadata = Scry.filter_capabilities(model: User)[:predicates][:computed_number]

    expect(metadata).to include(types: ["numerical"], applies_to: [:computed])
    expect { metadata[:types] << "textual" }.to raise_error(FrozenError)
  end

  it "applies each expression property's predicate permission to computed predicates" do
    record = create(:user, first_name: "Ada")
    Scry.configuration.register_predicate(:computed_number, types: [:numerical], applies_to: [:computed], compounds: false) do |attribute, value|
      attribute.eq(value)
    end
    User.add_filter_permission(:property_predicates, list_type: :excludelist) { {id: [:computed_number]} }

    filter = group(type: "computed", expression: {operator: "add", operands: [{property: "id"}, {literal: 0}]}, predicate: "computed_number", args: [record.id])

    result = Scry.filter_records_by(records: User.where(id: record.id), filter:)

    expect(result.diagnostics.map(&:code)).to include(:predicate_denied)
  end

  it "uses aggregate result types for COUNT and MAX applicability" do
    user = create(:user, emails_count: 0)
    user.emails << create(:email, address: "one@example.test")
    count = group(type: "aggregate", association: "emails", aggregate: "count", predicate: "gt", args: [0])
    count_string = group(type: "aggregate", association: "emails", aggregate: "count", predicate: "matches", args: ["1"])
    max_date = group(type: "aggregate", association: "emails", aggregate: "max", property: "created_at", predicate: "gteq", args: [Time.current - 1.day])

    expect(Scry.filter_records_by(records: User.where(id: user.id), filter: count).relation.ids).to eq([user.id])
    expect(Scry.filter_records_by(records: User.where(id: user.id), filter: count_string).diagnostics.map(&:code)).to include(:aggregate_denied)
    expect(Scry.filter_records_by(records: User.where(id: user.id), filter: max_date).relation.ids).to eq([user.id])
  end
end
