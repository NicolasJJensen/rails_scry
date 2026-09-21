# frozen_string_literal: true

require_relative "support"

RSpec.describe "Adapter execution constraints", :interoperability do
  it "rejects an incompatible predicate after a property grants every predicate" do
    Scry.configuration.register_predicate(:other_adapter, types: [:textual], adapters: [:sqlite3],
      compounds: false, arel_predicate: :eq)
    User.add_filter_permission(:property_predicates) { {first_name: :all} }

    result = Scry.filter_records_by(records: User, filter: group(property("first_name", "other_adapter", "Selected")))

    expect(result.diagnostics.map(&:category)).to eq([:permission_denied])
    expect(result.diagnostics.map(&:code)).to eq([:predicate_denied])
    expect(result.relation.to_sql).not_to include("Selected")
  end

  it "enforces adapter support at execution even when a custom filter bypasses predicate permissions" do
    called = false
    Scry.configuration.register_predicate(:other_adapter, types: [:textual], adapters: [:sqlite3], compounds: false) do |attribute, value|
      called = true
      attribute.eq(value)
    end
    filter_class = Class.new(Scry::Filters::Property) do
      def valid_predicate?
        true
      end
    end
    Scry.configuration.register_filter(:trusted_property, filter_class)
    payload = property("first_name", "other_adapter", "Selected").merge(type: :trusted_property)

    result = Scry.filter_records_by(records: User, filter: group(payload))

    expect(called).to be(false)
    expect(result.diagnostics.first.message).to include("not supported by this adapter")
  end
end
