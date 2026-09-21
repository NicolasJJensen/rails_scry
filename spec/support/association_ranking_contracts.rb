# frozen_string_literal: true

# Adapter-neutral contracts for association scopes that rank rows before a
# per-owner limit. The boundary runner includes this shared group after its
# BoundaryOwner/BoundaryChild fixtures are defined.
RSpec.shared_examples "association ranking contracts" do
  it "deduplicates joined rows before applying a per-owner offset and limit" do
    @owner.has_many :ranked_children,
                    -> {
                      table = arel_table
                      scope = joins("CROSS JOIN (SELECT 1 AS copy UNION ALL SELECT 2 AS copy) copies")
                        .where(name: %w[rank_a rank_b])
                      scope.order(
                        Arel::Nodes::NullsLast.new(
                          Arel::Nodes::NamedFunction.new("LOWER", [table[:name]]).asc
                        ),
                        table[:id].asc
                      ).distinct.offset(1).limit(1)
                    },
                    class_name: "BoundaryChild",
                    foreign_key: :owner_id

    @child.create!(owner_id: @first.id, name: "rank_a", amount: 1, status: 1)
    first_ranked = @child.create!(owner_id: @first.id, name: "rank_b", amount: 2, status: 1)
    @child.create!(owner_id: @first.id, name: nil, amount: 5, status: 1)
    @child.create!(owner_id: @second.id, name: "rank_a", amount: 3, status: 1)
    second_ranked = @child.create!(owner_id: @second.id, name: "rank_b", amount: 4, status: 1)
    @child.create!(owner_id: @second.id, name: nil, amount: 6, status: 1)

    aggregate = ->(association, owner_id, amount) do
      boundary_filter({
        type: "aggregate", association:, aggregate: "min", property: "amount", predicate: "eq", args: [amount]
      }).where(id: owner_id)
    end

    expect(aggregate.call("ranked_children", @first.id, first_ranked.amount).ids).to eq([@first.id])
    expect(aggregate.call("ranked_children", @second.id, second_ranked.amount).ids).to eq([@second.id])
  end

  it "preserves descending NULLS LAST function ordering in a per-owner scope" do
    @owner.has_many :descending_children,
                    -> {
                      table = arel_table
                      where(name: %w[rank_a rank_b])
                        .order(
                          Arel::Nodes::NullsLast.new(
                            Arel::Nodes::NamedFunction.new("LOWER", [table[:name]]).desc
                          )
                        ).limit(1)
                    },
                    class_name: "BoundaryChild",
                    foreign_key: :owner_id

    @child.create!(owner_id: @first.id, name: "rank_a", amount: 1, status: 1)
    first_ranked = @child.create!(owner_id: @first.id, name: "rank_b", amount: 2, status: 1)
    @child.create!(owner_id: @first.id, name: nil, amount: 5, status: 1)

    expect(boundary_filter({
      type: "aggregate", association: "descending_children", aggregate: "min", property: "amount",
      predicate: "eq", args: [first_ranked.amount]
    }).ids).to eq([@first.id])
  end

  it "ranks grouped child scopes by a joined review aggregate per owner" do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_reviews, temporary: connection.adapter_name != "Mysql2") do |table|
      table.integer :child_id, null: false
      table.integer :score, null: false
    end
    stub_const("BoundaryReview", Class.new(ActiveRecord::Base))
    BoundaryReview.table_name = "af_boundary_reviews"
    @child.has_many :reviews, class_name: "BoundaryReview", foreign_key: :child_id
    BoundaryReview.belongs_to :child, class_name: "BoundaryChild", foreign_key: :child_id

    @owner.has_many :review_ranked_children,
                    -> {
                      review_table = reflect_on_association(:reviews).klass.arel_table
                      joins(:reviews)
                        .group(arel_table[:id])
                        .having(review_table[:score].maximum.gteq(15))
                        .order(review_table[:score].maximum.desc)
                        .limit(1)
                    },
                    class_name: "BoundaryChild",
                    foreign_key: :owner_id

    first_ranked = @child.create!(owner_id: @first.id, name: "review-a", amount: 10, status: 1)
    first_other = @child.create!(owner_id: @first.id, name: "review-b", amount: 20, status: 1)
    first_excluded = @child.create!(owner_id: @first.id, name: "review-low", amount: 5, status: 1)
    second_ranked = @child.create!(owner_id: @second.id, name: "review-c", amount: 30, status: 1)
    BoundaryReview.create!(child_id: first_ranked.id, score: 10)
    BoundaryReview.create!(child_id: first_other.id, score: 20)
    BoundaryReview.create!(child_id: first_excluded.id, score: 5)
    BoundaryReview.create!(child_id: second_ranked.id, score: 30)

    aggregate = ->(owner_id, amount) do
      boundary_filter({
        type: "aggregate", association: "review_ranked_children", aggregate: "min", property: "amount",
        predicate: "eq", args: [amount]
      }).where(id: owner_id)
    end

    expect(aggregate.call(@first.id, first_other.amount).ids).to eq([@first.id])
    expect(aggregate.call(@first.id, first_excluded.amount).ids).to be_empty
    expect(aggregate.call(@second.id, second_ranked.amount).ids).to eq([@second.id])
  ensure
    connection.drop_table(:af_boundary_reviews, if_exists: true)
  end

  it "deduplicates joined priority rows before applying a per-owner limit" do
    connection = ActiveRecord::Base.connection
    connection.create_table(:af_boundary_tags, temporary: connection.adapter_name != "Mysql2") do |table|
      table.integer :child_id, null: false
      table.integer :priority, null: false
    end
    stub_const("BoundaryTag", Class.new(ActiveRecord::Base))
    BoundaryTag.table_name = "af_boundary_tags"
    @child.has_many :tags, class_name: "BoundaryTag", foreign_key: :child_id
    BoundaryTag.belongs_to :child, class_name: "BoundaryChild", foreign_key: :child_id

    @owner.has_many :priority_ranked_children,
                    -> {
                      tag_table = reflect_on_association(:tags).klass.arel_table
                      joins(:tags).distinct.order(tag_table[:priority].desc, arel_table[:amount].desc, arel_table[:id].asc).limit(2)
                    },
                    class_name: "BoundaryChild",
                    foreign_key: :owner_id

    first = @child.create!(owner_id: @first.id, name: "priority-one", amount: 10, status: 1)
    second = @child.create!(owner_id: @first.id, name: "priority-two", amount: 20, status: 1)
    BoundaryTag.create!(child_id: first.id, priority: 100)
    BoundaryTag.create!(child_id: first.id, priority: 99)
    BoundaryTag.create!(child_id: second.id, priority: 98)

    result = boundary_filter({type: "association", association: "priority_ranked_children", predicate: "has_any", args: [[second.id]]})

    expect(result.ids).to eq([@first.id])
  ensure
    connection&.drop_table(:af_boundary_tags, if_exists: true)
  end

  it "preserves joined distinct candidates through grouped has_all membership" do
    candidates = @child.joins(:owner).select(@child.arel_table[:id]).distinct
      .where(af_boundary_owners: {id: @first.id})
      .order(@child.arel_table[:name].asc).limit(2)

    expect(boundary_filter(boundary_association("has_all", candidates)).ids).to eq([@first.id])
  end
end
