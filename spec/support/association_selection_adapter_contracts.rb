# frozen_string_literal: true

# These examples use the adapter-neutral BoundaryOwner/BoundaryChild fixture
# supplied by interoperability_boundaries.rb. The adapter runner can include
# this shared group after loading its normal interoperability setup.
RSpec.shared_examples "association selection adapter contracts" do
  it "rejects hash association operands" do
    [{}, {id: @a.id}].each do |value|
      %w[has_any has_all only_has_all].each do |predicate|
        expect {
          boundary_filter({
            type: "association",
            association: "children",
            predicate:,
            args: [value]
          })
        }.to raise_error(Scry::FilterError, /association ID is invalid|composite key value is invalid/),
          "#{predicate} with #{value.inspect}"
      end
    end
  end

  it "applies an offset-only association scope per owner" do
    @owner.has_many :after_first_children,
                    -> { order(id: :asc).offset(1) },
                    class_name: "BoundaryChild",
                    foreign_key: :owner_id

    filter = ->(ids) do
      boundary_filter({
        type: "association",
        association: "after_first_children",
        predicate: "has_any",
        args: [ids]
      })
    end

    expect(filter.call([@a.id])).to be_empty
    expect(filter.call([@b.id]).ids).to eq([@first.id])
  end
end
