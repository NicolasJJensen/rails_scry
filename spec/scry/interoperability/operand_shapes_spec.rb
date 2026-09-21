# frozen_string_literal: true

require_relative "support"
require_relative "temporary_table_support"

RSpec.describe "Structured comparison operands", :interoperability do
  %w[json jsonb].each do |column_type|
    it "compares complete #{column_type} arrays and compound alternatives" do
      with_temporary_table("af_operand_#{column_type}", "id bigint PRIMARY KEY, document #{column_type} NOT NULL") do |table|
        model = temporary_model("InteroperabilityTemporary::OperandRecord", table)
        model.create!(id: 1, document: ["ruby", {"frameworks" => ["rails"]}])
        model.create!(id: 2, document: ["python"])
        model.create!(id: 3, document: [])
        value = ["ruby", {"frameworks" => ["rails"]}]

        expect(apply(model, property("document", "eq", value)).ids).to eq([1])
        expect(apply(model, property("document", "not_eq", value)).ids.sort).to eq([2, 3])
        expect(apply(model, property("document", "eq", [])).ids).to eq([3])
        expect(apply(model, property("document", "eq_any", [value, ["python"]])).ids.sort).to eq([1, 2])
        expect(apply(model, property("document", "eq_all", [value, value])).ids).to eq([1])
      end
    end
  end

  it "passes a complete array to an ActiveRecord JSON serializer on a text column" do
    with_temporary_table("af_serialized_operands", "id bigint PRIMARY KEY, document text NOT NULL") do |table|
      model = temporary_model("InteroperabilityTemporary::SerializedOperandRecord", table)
      model.serialize :document, coder: JSON
      model.create!(id: 1, document: ["ruby", "rails"])
      model.create!(id: 2, document: ["python"])

      expect(apply(model, property("document", "eq", ["ruby", "rails"])).ids).to eq([1])
      expect(apply(model, property("document", "eq_any", [["ruby", "rails"], ["python"]])).ids.sort).to eq([1, 2])
    end
  end

  it "matches literal SQL wildcard characters" do
    matching = create(:user, first_name: "rate_50%")
    other = create(:user, first_name: "rateX50percent")
    scope = User.where(id: [matching.id, other.id])

    expect(apply(scope, property("first_name", "matches", "_50%")).ids).to eq([matching.id])
    expect(apply(scope, property("first_name", "does_not_match", "_50%")).ids).to eq([other.id])
    expect(apply(scope, property("first_name", "matches_any", ["_50%", "unmatched"])).ids).to eq([matching.id])
  end
end
