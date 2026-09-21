# frozen_string_literal: true

require_relative "support"
require_relative "temporary_table_support"

module InteroperabilityExtensionFixtures
  class JoinedRelationFilter < Scry::Filters::Base
    def apply
      success(@scope.joins(:emails).where(emails: { address: @filter.fetch(:address) }))
    end
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe "Extension interoperability contracts", interoperability: true do
  it "composes a relation-returning custom filter with OR while preserving the caller scope" do
    organisation = create(:organisation)
    other_organisation = create(:organisation)
    in_scope = create(:user, organisation: organisation, first_name: "Property match")
    out_of_scope = create(:user, organisation: other_organisation, first_name: "Joined match")
    out_of_scope.emails << create(:email, address: "joined@example.test")

    config = Scry.configuration
    config.register_filter(:joined_relation, InteroperabilityExtensionFixtures::JoinedRelationFilter)
    filter = {
      type: "joined_relation", address: "joined@example.test"
    }

    result = apply(
      User.where(organisation_id: organisation.id),
      filter,
      property("first_name", "eq", "Property match"),
      predicate: "or"
    )

    expect(result.ids).to eq([in_scope.id])
  end

  it "negates a relation-returning custom filter without dropping the caller scope" do
    organisation = create(:organisation)
    included = create(:user, organisation: organisation, first_name: "Included")
    excluded = create(:user, organisation: organisation, first_name: "Excluded")
    included.emails << create(:email, address: "joined@example.test")

    config = Scry.configuration
    config.register_filter(:joined_relation, InteroperabilityExtensionFixtures::JoinedRelationFilter)
    result = apply(
      User.where(organisation_id: organisation.id),
      { type: "joined_relation", address: "joined@example.test" },
      negate: true
    )

    expect(result.ids).to eq([excluded.id])
  end

  it "uses a registered aggregate builder and passes the distinct option to it" do
    seen_distinct = []
    config = Scry.configuration
    config.register_aggregate(
      :custom,
      types: [:summable],
      result_type: :numerical,
      empty_value: 0
    ) do |attribute, distinct|
      seen_distinct << distinct
      Arel::Nodes::Sum.new([attribute]).tap { |node| node.distinct = distinct }
    end

    technician = Technician.create!(name: "Custom aggregate")
    job = Job.create!(title: "Custom aggregate")
    [2, 3].each do |minutes|
      ScheduleAssignment.create!(technician: technician, job: job, travel_time_minutes: minutes)
    end

    result = apply(
      Technician.where(id: technician.id),
      aggregate(
        "schedule_assignments", "eq", 5,
        aggregate: "custom", property: "travel_time_minutes", distinct?: true
      )
    )

    expect(result.ids).to eq([technician.id])
    expect(seen_distinct).to include(true)
  end

  it "keeps custom property metadata and execution aligned for a worker context" do
    User.add_custom_property_filter(
      type: :boolean,
      label: "VIP customer"
    ) do
      {
        vip: {
          type: "group", predicate: "and", filters: [
            { type: "property", property: "first_name", predicate: "eq", args: ["Worker target"] }
          ]
        }
      }
    end

    metadata = User.filter_capabilities[:properties].find { |item| item[:key] == "vip" }
    expect(metadata).to include(type: "boolean", label: "VIP customer")
    expect(User.filter_predicate_permissions[:vip]).to contain_exactly(:eq_true, :eq_false)

    target = create(:user, first_name: "Worker target")
    worker_result = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Scry.filter_records_by(
          records: User.where(id: target.id), context: nil,
          filter: { type: "group", predicate: "and", filters: [
            { type: "property", property: "vip", predicate: "eq_true" }
          ] }
        ).relation.ids
      end
    end.value
    expect(worker_result).to eq([target.id])
  end
end
# rubocop:enable Metrics/BlockLength
