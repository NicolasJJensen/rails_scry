# frozen_string_literal: true

require "rails_helper"

RSpec.describe "nested custom scope contracts" do
  around do |example|
    Scry.configuration.with_temporary_settings { example.run }
  end

  it "qualifies aliased projections and pages custom nested relations within the caller universe" do
    custom_filter = Class.new(Scry::Filters::Base) do
      def apply
        success(
          source_relation
            .where(source_attribute(:first_name).not_eq("excluded"))
            .order(source_attribute(:id).asc)
            .limit(1)
        )
      end
    end
    Scry.configuration.register_filter(:nested_custom_scope, custom_filter)

    organisation = Organisation.create!(name: "Nested custom scope")
    excluded = User.create!(organisation:, first_name: "excluded")
    matching = User.create!(organisation:, first_name: "matching")
    other = User.create!(organisation:, first_name: "other")
    caller_relation = User
      .from(User.arel_table.alias("nested_custom_users"))
      .where(nested_custom_users: { id: [matching.id, other.id] })
      .select("nested_custom_users.*")

    root = Scry.filter_records_by(
      records: caller_relation,
      filter: { type: :nested_custom_scope }
    )
    nested = Scry.filter_records_by(
      records: caller_relation,
      filter: {
        type: :group,
        predicate: :and,
        filters: [{ type: :nested_custom_scope }]
      }
    )
    negated = Scry.filter_records_by(
      records: caller_relation,
      filter: {
        type: :group,
        predicate: :and,
        negate: true,
        filters: [{ type: :nested_custom_scope }]
      }
    )

    expect(excluded).to be_persisted
    expect(root.relation.ids).to eq([matching.id])
    expect(nested.relation.ids).to eq([matching.id])
    expect(negated.relation.ids).to eq([other.id])
  end
end
