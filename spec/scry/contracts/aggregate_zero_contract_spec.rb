# frozen_string_literal: true

require "rails_helper"

RSpec.describe "aggregate zero counts" do
  it "matches owners with no related rows without an include_zero flag" do
    empty = create(:user)
    populated = create(:user)
    populated.emails << create(:email)

    result = Scry.filter_records_by(
      records: User.where(id: [empty.id, populated.id]),
      context: nil,
      filter: {
        type: "group", predicate: "and", filters: [{
          type: "aggregate", association: "emails", aggregate: "count",
          predicate: "eq", args: [0]
        }]
      }
    )

    expect(result).to be_success
    expect(result.relation).to contain_exactly(empty)
  end
end
