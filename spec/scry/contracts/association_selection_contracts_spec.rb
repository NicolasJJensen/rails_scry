# frozen_string_literal: true

require_relative "../interoperability/support"
require_relative "../interoperability/temporary_table_support"

RSpec.describe "association selection contracts", :interoperability do
  def association_filter(name, predicate, value, scoping: nil, target_type: nil)
    filter = {
      type: "group",
      predicate: "and",
      filters: [{ type: "association", association: name, predicate:, args: [value] }]
    }
    filter[:filters].first[:scoping] = scoping if scoping
    filter[:filters].first[:target_type] = target_type if target_type
    filter
  end

  def apply_association(scope, name, predicate, value, scoping: nil, target_type: nil)
    apply_association_result(scope, name, predicate, value, scoping:, target_type:).relation
  end

  def apply_association_result(scope, name, predicate, value, scoping: nil, target_type: nil)
    Scry.filter_records_by(
      records: scope,
      context: nil,
      filter: association_filter(name, predicate, value, scoping:, target_type:)
    )
  end

  it "rejects hash association operands instead of treating an empty hash as an empty set" do
    with_temporary_table("af_selection_hash_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table("af_selection_hash_children", "id bigint PRIMARY KEY, owner_id bigint NOT NULL") do |children|
        owner = temporary_model("AssociationSelection::HashOwner", owners)
        child = temporary_model("AssociationSelection::HashChild", children)
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        owner.create!(id: 1)

        Scry.configuration.with_temporary_settings do |config|
          config.invalid_filter_policy = :raise
          [%{}, {id: 1}].each do |value|
            %w[has_any has_all only_has_all].each do |predicate|
              expect { apply_association(owner, "children", predicate, value) }
                .to raise_error(Scry::FilterError, /association ID is invalid|composite key value is invalid/),
                  "#{predicate} with #{value.inspect}"
            end
          end
        end
      end
    end
  end

  it "selects each owner's ordered limit and offset window independently" do
    with_temporary_table("af_selection_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, position integer NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::Owner", owners)
        child = temporary_model("AssociationSelection::Child", children)
        owner.has_many :windowed_children, -> { order(position: :asc, id: :asc).limit(1).offset(1) },
                       class_name: child.name, foreign_key: :owner_id

        first = owner.create!(id: 1)
        second = owner.create!(id: 2)
        first_rows = [1, 2, 3].map { |position| child.create!(id: position, owner_id: first.id, position:) }
        second_rows = [4, 5, 6].map { |position| child.create!(id: position, owner_id: second.id, position: position - 3) }

        expect(first.windowed_children.ids).to eq([first_rows[1].id])
        expect(second.windowed_children.ids).to eq([second_rows[1].id])
        expect(apply_association(owner, "windowed_children", "has_any", [first_rows[0].id, second_rows[0].id]))
          .to be_empty
      expect(apply_association(owner, "windowed_children", "has_any", [first_rows[1].id, second_rows[1].id]).ids)
          .to eq([first.id, second.id])
      end
    end
  end

  it "uses all selected rows as zero-operand candidates for each limited owner" do
    with_temporary_table("af_selection_zero_operand_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_zero_operand_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::ZeroOperandOwner", owners)
        child = temporary_model("AssociationSelection::ZeroOperandChild", children)
        owner.has_many :second_children, -> { order(id: :asc).limit(1).offset(1) },
          class_name: child.name, foreign_key: :owner_id

        first = owner.create!(id: 1)
        second = owner.create!(id: 2)
        child.create!(id: 1, owner_id: first.id)
        child.create!(id: 2, owner_id: first.id)
        child.create!(id: 3, owner_id: second.id)
        child.create!(id: 4, owner_id: second.id)

        filter = {
          type: "group", predicate: "and", filters: [{
            type: "association", association: "second_children", predicate: "has_any", args: []
          }]
        }
        result = Scry.filter_records_by(records: owner, context: nil, filter:).relation

        expect(result.ids).to contain_exactly(first.id, second.id)
      end
    end
  end

  it "applies an offset-only association scope per owner" do
    with_temporary_table("af_selection_offset_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_offset_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, position integer NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::OffsetOwner", owners)
        child = temporary_model("AssociationSelection::OffsetChild", children)
        owner.has_many :after_first_children, -> { order(position: :asc, id: :asc).offset(1) },
                      class_name: child.name, foreign_key: :owner_id

        record = owner.create!(id: 1)
        rows = [1, 2, 3].map { |position| child.create!(id: position, owner_id: record.id, position:) }

        expect(record.after_first_children.ids).to eq([rows[1].id, rows[2].id])
        expect(apply_association(owner, "after_first_children", "has_any", [rows[0].id])).to be_empty
        expect(apply_association(owner, "after_first_children", "has_any", [rows[1].id]).ids).to eq([record.id])
      end
    end
  end

  it "uses a stable child-key tie breaker for equal association order values" do
    with_temporary_table("af_selection_tie_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_tie_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, position integer NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::TieOwner", owners)
        child = temporary_model("AssociationSelection::TieChild", children)
        owner.has_many :first_children, -> { order(position: :asc).limit(1) },
                      class_name: child.name, foreign_key: :owner_id

        record = owner.create!(id: 1)
        first = child.create!(id: 1, owner_id: record.id, position: 1)
        second = child.create!(id: 2, owner_id: record.id, position: 1)

        expect(record.first_children.ids).to eq([first.id])
        expect(apply_association(owner, "first_children", "has_any", [first.id]).ids).to eq([record.id])
        expect(apply_association(owner, "first_children", "has_any", [second.id])).to be_empty
      end
    end
  end

  it "applies nested filter scoping after selecting the association row" do
    with_temporary_table("af_selection_payment_users", "id bigint PRIMARY KEY") do |users|
      with_temporary_table(
        "af_selection_payments",
        "id bigint PRIMARY KEY, user_id bigint NOT NULL, status varchar NOT NULL, created_at timestamp NOT NULL"
      ) do |payments|
        user = temporary_model("AssociationSelection::PaymentUser", users)
        payment = temporary_model("AssociationSelection::Payment", payments)
        user.has_many :latest_payments, -> { order(created_at: :desc, id: :desc).limit(1) },
                      class_name: payment.name, foreign_key: :user_id

        record = user.create!(id: 1)
        payment.create!(id: 1, user_id: record.id, status: "failed", created_at: 2.days.ago)
        payment.create!(id: 2, user_id: record.id, status: "paid", created_at: 1.day.ago)
        scoping = {
          type: "group",
          predicate: "and",
          filters: [{ type: "property", property: "status", predicate: "eq", args: ["failed"] }]
        }

        expect(record.latest_payments.pluck(:id)).to eq([2])
        expect(apply_association(record.class, "latest_payments", "has_any", [1], scoping:)).to be_empty
      end
    end
  end

  it "applies a child default scope before per-owner ranking" do
    with_temporary_table("af_selection_default_scope_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_default_scope_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, active boolean NOT NULL, position integer NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::DefaultScopeOwner", owners)
        child = temporary_model("AssociationSelection::DefaultScopeChild", children)
        child.send(:default_scope) { where(active: true) }
        owner.has_many :latest_children, -> { order(position: :desc, id: :desc).limit(1) },
                      class_name: child.name, foreign_key: :owner_id

        record = owner.create!(id: 1)
        active = child.create!(id: 1, owner_id: record.id, active: true, position: 1)
        child.unscoped.create!(id: 2, owner_id: record.id, active: false, position: 2)

        expect(record.latest_children.ids).to eq([active.id])
        expect(apply_association(owner, "latest_children", "has_any", [active.id]).ids).to eq([record.id])
        expect(apply_association(owner, "latest_children", "has_any", [2])).to be_empty
      end
    end
  end

  it "routes a custom association predicate through its callback" do
    with_temporary_table("af_selection_custom_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_custom_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::CustomOwner", owners)
        child = temporary_model("AssociationSelection::CustomChild", children)
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        record = owner.create!(id: 1)
        child.create!(id: 1, owner_id: record.id)
        called = false

        Scry.configuration.with_temporary_settings do |config|
          config.register_predicate(:has_any, types: [:many_association], applies_to: [:association], compounds: false) do |attribute, value|
            called = true
            Scry::AssociationQuery.for_attribute(attribute).has_any(value)
          end

          definition = config.predicate_registry.by_name(:has_any)
          expect(definition[:custom_predicate]).to be_present

          expect(apply_association(owner, "children", "has_any", [1]).ids).to eq([record.id])
        end

        expect(called).to be(true)
      end
    end
  end

  it "uses the ordered row for has_one when several rows share the foreign key" do
    with_temporary_table("af_selection_has_one_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_has_one_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::HasOneOwner", owners)
        child = temporary_model("AssociationSelection::HasOneChild", children)
        owner.has_one :latest_child, -> { order(id: :desc) }, class_name: child.name, foreign_key: :owner_id

        record = owner.create!(id: 1)
        older = child.create!(id: 1, owner_id: record.id)
        newest = child.create!(id: 2, owner_id: record.id)

        expect(record.latest_child.id).to eq(newest.id)
        expect(apply_association(owner, "latest_child", "has_any", [older.id])).to be_empty
      end
    end
  end

  it "preserves self-referential through joins and aliases" do
    with_temporary_table(
      "af_selection_tree_nodes",
      "id bigint PRIMARY KEY, parent_id bigint"
    ) do |nodes|
      node = temporary_model("AssociationSelection::TreeNode", nodes)
      node.has_many :children, class_name: node.name, foreign_key: :parent_id
      node.has_many :grandchildren, through: :children, source: :children

      root = node.create!(id: 1)
      child = node.create!(id: 2, parent_id: root.id)
      grandchild = node.create!(id: 3, parent_id: child.id)

      expect(apply_association(node, "grandchildren", "has_any", [grandchild.id]).ids).to eq([root.id])
    end
  end

  it "ranks a scoped self-referential through association per owner" do
    with_temporary_table(
      "af_selection_ranked_tree_nodes",
      "id bigint PRIMARY KEY, parent_id bigint, position integer NOT NULL"
    ) do |nodes|
      node = temporary_model("AssociationSelection::RankedTreeNode", nodes)
      node.has_many :children, class_name: node.name, foreign_key: :parent_id
      node.has_many :latest_grandchildren,
                   -> { order(position: :desc, id: :desc).limit(1) },
                   through: :children,
                   source: :children

      root = node.create!(id: 1, position: 0)
      child = node.create!(id: 2, parent_id: root.id, position: 0)
      older = node.create!(id: 3, parent_id: child.id, position: 1)
      latest = node.create!(id: 4, parent_id: child.id, position: 2)

      expect(root.latest_grandchildren.ids).to eq([latest.id])
      result = apply_association(node, "latest_grandchildren", "has_any", [latest.id])
      expect(result.ids).to eq([root.id])
      expect(apply_association(node, "latest_grandchildren", "has_any", [older.id])).to be_empty
    end
  end

  it "counts only the selected per-owner row for aggregate filters" do
    with_temporary_table("af_selection_aggregate_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_aggregate_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, position integer NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::AggregateOwner", owners)
        child = temporary_model("AssociationSelection::AggregateChild", children)
        owner.has_many :latest_children, -> { order(position: :desc, id: :desc).limit(1) },
                       class_name: child.name, foreign_key: :owner_id

        first = owner.create!(id: 1)
        second = owner.create!(id: 2)
        child.create!(id: 1, owner_id: first.id, position: 1)
        child.create!(id: 2, owner_id: first.id, position: 2)
        child.create!(id: 3, owner_id: second.id, position: 1)

        filter = {
          type: "group",
          predicate: "and",
          filters: [{
            type: "aggregate", association: "latest_children", aggregate: "count",
            predicate: "eq", args: [1]
          }]
        }
        expect(Scry.filter_records_by(records: owner, context: nil, filter:).relation.ids)
          .to eq([first.id, second.id])
      end
    end
  end

  it "continues to reject arbitrary owner-dependent scopes" do
    with_temporary_table("af_selection_owner_dependent_owners", "id bigint PRIMARY KEY, currency varchar NOT NULL") do |owners|
      with_temporary_table(
        "af_selection_owner_dependent_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, currency varchar NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::OwnerDependentOwner", owners)
        child = temporary_model("AssociationSelection::OwnerDependentChild", children)
        owner.has_many :matching_children, ->(record) { where(currency: record.currency) },
                       class_name: child.name, foreign_key: :owner_id
        owner.create!(id: 1, currency: "AUD")

        Scry.configuration.with_temporary_settings do |config|
          config.invalid_filter_policy = :raise
          expect do
            apply_association(owner, "matching_children", "has_any", [1])
          end.to raise_error(Scry::FilterError, /instance-dependent scopes are not supported/)
        end
      end
    end
  end

  it "matches composite parent keys across every key column" do
    with_temporary_table(
      "af_selection_composite_owners",
      "tenant_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (tenant_id, code)"
    ) do |owners|
      with_temporary_table(
        "af_selection_composite_children",
        "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, code varchar NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::CompositeOwner", owners)
        child = temporary_model("AssociationSelection::CompositeChild", children)
        owner.primary_key = %w[tenant_id code]
        owner.query_constraints :tenant_id, :code
        child.query_constraints :tenant_id, :code
        owner.has_many :children, class_name: child.name, foreign_key: %i[tenant_id code]

        first = owner.create!(tenant_id: 1, code: "A")
        second = owner.create!(tenant_id: 2, code: "A")
        first_child = child.create!(id: 1, tenant_id: 1, code: "A")
        second_child = child.create!(id: 2, tenant_id: 2, code: "A")

        expect(apply_association(owner, "children", "has_any", [first_child.id]).ids)
          .to eq([[first.tenant_id, first.code]])
        expect(apply_association(owner, "children", "has_any", [second_child.id]).ids)
          .to eq([[second.tenant_id, second.code]])
      end
    end
  end

  it "ranks limited associations independently for composite parent keys" do
    with_temporary_table(
      "af_selection_composite_rank_owners",
      "tenant_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (tenant_id, code)"
    ) do |owners|
      with_temporary_table(
        "af_selection_composite_rank_children",
        "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, code varchar NOT NULL, position integer NOT NULL"
      ) do |children|
        owner = temporary_model("AssociationSelection::CompositeRankOwner", owners)
        child = temporary_model("AssociationSelection::CompositeRankChild", children)
        owner.primary_key = %w[tenant_id code]
        owner.query_constraints :tenant_id, :code
        child.query_constraints :tenant_id, :code
        owner.has_many :latest_children, -> { order(position: :desc, id: :desc).limit(1) },
                      class_name: child.name, foreign_key: %i[tenant_id code]

        first = owner.create!(tenant_id: 1, code: "A")
        second = owner.create!(tenant_id: 2, code: "A")
        first_old = child.create!(id: 1, tenant_id: 1, code: "A", position: 1)
        first_new = child.create!(id: 2, tenant_id: 1, code: "A", position: 2)
        second_old = child.create!(id: 3, tenant_id: 2, code: "A", position: 1)
        second_new = child.create!(id: 4, tenant_id: 2, code: "A", position: 2)

        expect(first.latest_children.ids).to eq([first_new.id])
        expect(second.latest_children.ids).to eq([second_new.id])
        expect(apply_association(owner, "latest_children", "has_any", [first_new.id, second_new.id]).ids)
          .to contain_exactly([first.tenant_id, first.code], [second.tenant_id, second.code])
        expect(apply_association(owner, "latest_children", "has_any", [first_old.id, second_old.id])).to be_empty
      end
    end
  end

  it "deduplicates composite candidate tuples before set aggregates" do
    with_temporary_table("af_selection_cpk_set_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_cpk_set_children",
        "owner_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (owner_id, code)"
      ) do |children|
        with_temporary_table(
          "af_selection_cpk_set_tags",
          "id bigint PRIMARY KEY, child_owner_id bigint NOT NULL, child_code varchar NOT NULL"
        ) do |tags|
          owner = temporary_model("AssociationSelection::CpkSetOwner", owners)
          child = temporary_model("AssociationSelection::CpkSetChild", children)
          tag = temporary_model("AssociationSelection::CpkSetTag", tags)
          owner.has_many :children, class_name: child.name, foreign_key: :owner_id
          child.primary_key = %w[owner_id code]
          tag.query_constraints :child_owner_id, :child_code
          child.has_many :tags, class_name: tag.name, foreign_key: %i[child_owner_id child_code]

          record = owner.create!(id: 1)
          selected = child.create!(owner_id: record.id, code: "selected")
          child.create!(owner_id: record.id, code: "other")
          tag.create!(id: 1, child_owner_id: selected.owner_id, child_code: selected.code)
          tag.create!(id: 2, child_owner_id: selected.owner_id, child_code: selected.code)
          candidates = child.joins(:tags).where(owner_id: record.id, code: selected.code)

          filter = {
            type: "group", predicate: "and", filters: [{
              type: "association", association: "children", predicate: "has_all", args: [candidates]
            }]
          }
          expect(Scry.filter_records_by(records: owner, context: nil, filter:).relation.ids).to eq([record.id])
        end
      end
    end
  end

  it "rejects a distinct candidate projection sourced from the associated owner key" do
    with_temporary_table("af_selection_identity_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table("af_selection_identity_children", "id bigint PRIMARY KEY, owner_id bigint NOT NULL") do |children|
        owner = temporary_model("AssociationSelection::IdentityOwner", owners)
        child = temporary_model("AssociationSelection::IdentityChild", children)
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        child.belongs_to :owner, class_name: owner.name, foreign_key: :owner_id

        record = owner.create!(id: 1)
        child.create!(id: 10, owner_id: record.id)
        candidates = child.joins(:owner).select(owner.arel_table[:id].as("id")).distinct

        Scry.configuration.with_temporary_settings do |config|
          config.invalid_filter_policy = :raise
          expect {
            apply_association(owner, "children", "has_any", candidates)
          }.to raise_error(Scry::FilterError, /candidate projection|primary key/)
        end
      end
    end
  end

  it "applies belongs_to scope joins, including chained inner and left joins" do
    with_temporary_table("af_selection_scoped_tickets", "id bigint PRIMARY KEY, review_id bigint") do |tickets|
      with_temporary_table(
        "af_selection_scoped_reviews",
        "id bigint PRIMARY KEY, author_id bigint NOT NULL, category_id bigint"
      ) do |reviews|
        with_temporary_table("af_selection_scoped_authors", "id bigint PRIMARY KEY, active boolean NOT NULL") do |authors|
          with_temporary_table("af_selection_scoped_categories", "id bigint PRIMARY KEY, name varchar NOT NULL") do |categories|
            ticket = temporary_model("AssociationSelection::ScopedTicket", tickets)
            review = temporary_model("AssociationSelection::ScopedReview", reviews)
            author = temporary_model("AssociationSelection::ScopedAuthor", authors)
            category = temporary_model("AssociationSelection::ScopedCategory", categories)

            review.belongs_to :author, class_name: author.name, foreign_key: :author_id
            review.belongs_to :category, class_name: category.name, foreign_key: :category_id, optional: true
            ticket.belongs_to :review,
                             -> { joins(:author).left_joins(:category).merge(AssociationSelection::ScopedAuthor.where(active: true)) },
                             class_name: review.name, foreign_key: :review_id, optional: true

            active_author = author.create!(id: 1, active: true)
            inactive_author = author.create!(id: 2, active: false)
            category.create!(id: 1, name: "verified")
            with_category = review.create!(id: 10, author_id: active_author.id, category_id: 1)
            without_category = review.create!(id: 11, author_id: active_author.id, category_id: nil)
            inactive = review.create!(id: 12, author_id: inactive_author.id, category_id: nil)
            first = ticket.create!(id: 1, review_id: with_category.id)
            second = ticket.create!(id: 2, review_id: without_category.id)
            third = ticket.create!(id: 3, review_id: inactive.id)
            empty = ticket.create!(id: 4, review_id: nil)

            expect(first.review.id).to eq(with_category.id)
            expect(second.review.id).to eq(without_category.id)
            expect(third.review).to be_nil
            expect(empty.review).to be_nil
            expect(apply_association(ticket, "review", "has_any", [with_category.id, without_category.id]).ids)
              .to contain_exactly(first.id, second.id)
            expect(apply_association(ticket, "review", "has_any", [inactive.id])).to be_empty
          end
        end
      end
    end
  end

  it "retains joined rows for per-owner has_many limits and preserves multiplicity for aggregates" do
    with_temporary_table("af_selection_joined_limit_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_joined_limit_reviews",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, score integer NOT NULL"
      ) do |reviews|
        with_temporary_table("af_selection_joined_limit_tags", "id bigint PRIMARY KEY, review_id bigint NOT NULL, priority integer NOT NULL") do |tags|
          owner = temporary_model("AssociationSelection::JoinedLimitOwner", owners)
          review = temporary_model("AssociationSelection::JoinedLimitReview", reviews)
          tag = temporary_model("AssociationSelection::JoinedLimitTag", tags)
          review.belongs_to :owner, class_name: owner.name, foreign_key: :owner_id
          review.has_many :tags, class_name: tag.name, foreign_key: :review_id
          owner.has_many :reviews, class_name: review.name, foreign_key: :owner_id
          owner.has_many :top_reviews, -> {
            tag_table = reflect_on_association(:tags).klass.arel_table
            review_table = arel_table
            joins(:tags).order(tag_table[:priority].desc, review_table[:score].desc, review_table[:id].asc).limit(3)
          },
                        class_name: review.name, foreign_key: :owner_id
          owner.has_many :latest_review, -> {
            tag_table = reflect_on_association(:tags).klass.arel_table
            review_table = arel_table
            joins(:tags).order(tag_table[:priority].desc, review_table[:score].desc, review_table[:id].asc).distinct.limit(1)
          }, class_name: review.name, foreign_key: :owner_id
          owner.has_many :top_two_reviews, -> {
            tag_table = reflect_on_association(:tags).klass.arel_table
            review_table = arel_table
            joins(:tags).order(tag_table[:priority].desc, review_table[:score].desc, review_table[:id].asc).distinct.limit(2)
          }, class_name: review.name, foreign_key: :owner_id

          first = owner.create!(id: 1)
          second = owner.create!(id: 2)
          first_best = review.create!(id: 10, owner_id: first.id, score: 10)
          first_next = review.create!(id: 9, owner_id: first.id, score: 100)
          first_excluded = review.create!(id: 8, owner_id: first.id, score: 8)
          second_best = review.create!(id: 20, owner_id: second.id, score: 20)
          second_next = review.create!(id: 19, owner_id: second.id, score: 200)
          tag.create!(id: 100, review_id: first_best.id, priority: 100)
          tag.create!(id: 101, review_id: first_best.id, priority: 99)
          tag.create!(id: 102, review_id: first_next.id, priority: 98)
          tag.create!(id: 103, review_id: first_excluded.id, priority: 97)
          tag.create!(id: 104, review_id: second_best.id, priority: 100)
          tag.create!(id: 105, review_id: second_next.id, priority: 98)

          expect(first.top_reviews.pluck(:id)).to eq([first_best.id, first_best.id, first_next.id])
          expect(second.top_reviews.pluck(:id)).to eq([second_best.id, second_next.id])
          Scry.configuration.invalid_filter_policy = :raise
          first_latest = apply_association_result(owner, "latest_review", "has_any", [first_best.id])
          expect(first_latest).to be_success, first_latest.diagnostics.map(&:to_h).inspect
          expect(first_latest.relation.ids).to eq([first.id])
          second_latest = apply_association_result(owner, "latest_review", "has_any", [second_best.id])
          expect(second_latest).to be_success, second_latest.diagnostics.map(&:to_h).inspect
          expect(second_latest.relation.ids).to eq([second.id])
          top_two = apply_association_result(owner, "top_two_reviews", "has_any", [first_next.id])
          expect(top_two).to be_success, top_two.diagnostics.map(&:to_h).inspect
          expect(top_two.relation.ids).to eq([first.id])
          expect(apply_association(owner, "top_reviews", "has_any", [first_next.id, second_best.id]).ids)
            .to contain_exactly(first.id, second.id)
          # The per-owner ranking must remain inside the caller's authorized
          # owner scope when the association is DISTINCT and joins another table.
          expect(apply_association(owner.where(id: second.id), "top_reviews", "has_any", [second_best.id]).ids)
            .to eq([second.id])
          expect(apply_association(owner, "top_reviews", "has_any", [first_excluded.id])).to be_empty
          expect(apply_association(owner, "top_reviews", "has_any", [second_next.id]).ids).to eq([second.id])
          expect(
            Scry.filter_records_by(
              records: owner,
              context: nil,
              filter: {
                type: "group", predicate: "and", filters: [{
                  type: "aggregate", association: "top_reviews", aggregate: "count", predicate: "eq", args: [3]
                }]
              }
            ).relation.ids
          ).to eq([first.id])
        end
      end
    end
  end

  it "deduplicates a declared child projection before applying per-owner ranking" do
    with_temporary_table("af_selection_distinct_limit_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_distinct_limit_reviews",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, score integer NOT NULL"
      ) do |reviews|
        with_temporary_table("af_selection_distinct_limit_tags", "id bigint PRIMARY KEY, review_id bigint NOT NULL") do |tags|
          owner = temporary_model("AssociationSelection::DistinctLimitOwner", owners)
          review = temporary_model("AssociationSelection::DistinctLimitReview", reviews)
          tag = temporary_model("AssociationSelection::DistinctLimitTag", tags)
          review.has_many :tags, class_name: tag.name, foreign_key: :review_id
          owner.has_many :distinct_top_reviews,
                        -> {
                          joins(:tags)
                            .select("af_selection_distinct_limit_reviews.id", "af_selection_distinct_limit_reviews.owner_id", "af_selection_distinct_limit_reviews.score")
                            .distinct
                            .order(
                              AssociationSelection::DistinctLimitReview.arel_table[:score].desc,
                              AssociationSelection::DistinctLimitReview.arel_table[:id].asc
                            )
                            .limit(1)
                        },
                        class_name: review.name, foreign_key: :owner_id

          record = owner.create!(id: 1)
          newest = review.create!(id: 10, owner_id: record.id, score: 10)
          older = review.create!(id: 9, owner_id: record.id, score: 9)
          tag.create!(id: 100, review_id: newest.id)
          tag.create!(id: 101, review_id: newest.id)
          tag.create!(id: 102, review_id: older.id)

          expect(record.distinct_top_reviews.map(&:id)).to eq([newest.id])
          expect(apply_association(owner, "distinct_top_reviews", "has_any", [newest.id]).ids).to eq([record.id])
          expect(apply_association(owner, "distinct_top_reviews", "has_any", [older.id])).to be_empty
        end
      end
    end
  end

  it "preserves grouped host relations while ranking a scoped child per owner" do
    with_temporary_table("af_selection_grouped_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_grouped_reviews",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, score integer NOT NULL"
      ) do |reviews|
        owner = temporary_model("AssociationSelection::GroupedOwner", owners)
        review = temporary_model("AssociationSelection::GroupedReview", reviews)
        owner.has_many :reviews, class_name: review.name, foreign_key: :owner_id
        owner.has_many :latest_reviews, -> { order(score: :desc, id: :asc).limit(1) },
                      class_name: review.name, foreign_key: :owner_id

        first = owner.create!(id: 1)
        second = owner.create!(id: 2)
        first_latest = review.create!(id: 10, owner_id: first.id, score: 10)
        review.create!(id: 9, owner_id: first.id, score: 9)
        second_latest = review.create!(id: 8, owner_id: second.id, score: 8)

        grouped = owner.joins(:reviews).group("af_selection_grouped_owners.id")
          .having("MAX(af_selection_grouped_reviews.score) >= 9")
        expect(grouped.ids).to eq([first.id])
        expect(apply_association(grouped, "latest_reviews", "has_any", [first_latest.id]).ids).to eq([first.id])
        expect(apply_association(grouped, "latest_reviews", "has_any", [second_latest.id])).to be_empty
      end
    end
  end

  it "ranks grouped child rows by an aggregate order per owner" do
    with_temporary_table("af_selection_child_group_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_selection_child_group_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL"
      ) do |children|
        with_temporary_table(
          "af_selection_child_group_reviews",
          "id bigint PRIMARY KEY, child_id bigint NOT NULL, score integer NOT NULL"
        ) do |reviews|
          owner = temporary_model("AssociationSelection::ChildGroupOwner", owners)
          child = temporary_model("AssociationSelection::ChildGroupChild", children)
          review = temporary_model("AssociationSelection::ChildGroupReview", reviews)
          child.belongs_to :owner, class_name: owner.name, foreign_key: :owner_id
          child.has_many :reviews, class_name: review.name, foreign_key: :child_id
          owner.has_many :ranked_children,
                        -> {
                          review_table = AssociationSelection::ChildGroupReview.arel_table
                          group(AssociationSelection::ChildGroupChild.arel_table[:id])
                            .joins(:reviews)
                            .having(review_table[:score].maximum.between(7..10))
                            .order(review_table[:score].maximum.desc)
                            .limit(3)
                        },
                        class_name: child.name, foreign_key: :owner_id

          first = owner.create!(id: 1)
          second = owner.create!(id: 2)
          first_a = child.create!(id: 10, owner_id: first.id)
          first_b = child.create!(id: 11, owner_id: first.id)
          first_c = child.create!(id: 12, owner_id: first.id)
          first_d = child.create!(id: 13, owner_id: first.id)
          second_a = child.create!(id: 20, owner_id: second.id)
          second_b = child.create!(id: 21, owner_id: second.id)
          review.create!(id: 100, child_id: first_a.id, score: 10)
          review.create!(id: 101, child_id: first_a.id, score: 9)
          review.create!(id: 102, child_id: first_b.id, score: 8)
          review.create!(id: 103, child_id: first_c.id, score: 7)
          review.create!(id: 104, child_id: first_d.id, score: 11)
          review.create!(id: 105, child_id: second_a.id, score: 8)
          review.create!(id: 106, child_id: second_b.id, score: 7)

          expect(first.ranked_children.ids).to eq([first_a.id, first_b.id, first_c.id])
          expect(second.ranked_children.ids).to eq([second_a.id, second_b.id])
          expect(apply_association(owner, "ranked_children", "has_any", [first_a.id, first_c.id]).ids)
            .to eq([first.id])
          expect(apply_association(owner, "ranked_children", "has_any", [first_d.id])).to be_empty
          expect(apply_association(owner, "ranked_children", "has_any", [second_a.id]).ids)
            .to eq([second.id])
          aggregate_filter = {
            type: "group", predicate: "and", filters: [{
              type: "aggregate", association: "ranked_children", aggregate: "count", predicate: "eq", args: [3]
            }]
          }
          expect(Scry.filter_records_by(records: owner, context: nil, filter: aggregate_filter).relation.ids)
            .to eq([first.id])
        end
      end
    end
  end

  it "uses only explicitly registered polymorphic targets for filtering and discovery" do
    with_temporary_table(
      "af_selection_polymorphic_comments",
      "id bigint PRIMARY KEY, commentable_type varchar NOT NULL, commentable_id bigint NOT NULL, kind varchar"
    ) do |comments|
      with_temporary_table("af_selection_polymorphic_posts", "id bigint PRIMARY KEY, type varchar, title varchar NOT NULL") do |posts|
        with_temporary_table("af_selection_polymorphic_photos", "id bigint PRIMARY KEY, caption varchar NOT NULL") do |photos|
          comment = temporary_model("AssociationSelection::Comment", comments)
          post = temporary_model("AssociationSelection::Post", posts)
          special_post = Class.new(post)
          stub_const("AssociationSelection::SpecialPost", special_post)
          special_post.table_name = post.table_name
          special_post.inheritance_column = :type
          photo = temporary_model("AssociationSelection::Photo", photos)
          comment.belongs_to :commentable, polymorphic: true
          post.has_many :comments, as: :commentable, class_name: comment.name
          post.has_one :visible_comment, -> { where(kind: "visible") }, as: :commentable, class_name: comment.name
          comment.add_filter_targets(:commentable, post: post, photo: photo)
          post.add_filter_targets(:comments, post: post)
          post.add_filter_targets(:visible_comment, post: post)
          comment.add_filter_permission(:associations, list_type: :includelist) { [:commentable] }
          photo.add_model_permission { false }

          target = post.create!(id: 7, title: "allowed")
          photo.create!(id: 7, caption: "same id, different type")
          special = special_post.create!(id: 8, type: "AssociationSelection::SpecialPost", title: "sti")
          comment.create!(id: 1, commentable_type: post.polymorphic_name, commentable_id: target.id, kind: "visible")
          comment.create!(id: 2, commentable_type: special.class.polymorphic_name, commentable_id: special.id)
          comment.create!(id: 3, commentable_type: photo.polymorphic_name, commentable_id: photo.find(7).id)
          comment.create!(id: 4, commentable_type: post.polymorphic_name, commentable_id: target.id, kind: "hidden")
          info = Scry.filter_capabilities(model: comment)

          expect(info[:associations]).to include(hash_including(key: "commentable"))
          expect(info[:association_targets]).to eq("commentable" => %w[post])
          expect(apply_association(comment, "commentable", "has_any", [target.id], target_type: "post").ids)
            .to eq([1, 4])
          expect(apply_association(comment, "commentable", "has_any", [special.id], target_type: "post").ids).to eq([2])
          Scry.configuration.with_temporary_settings do |config|
            config.invalid_filter_policy = :raise
            expect do
              apply_association(comment, "commentable", "has_any", [target.id], target_type: "unknown")
            end.to raise_error(Scry::FilterError)
            expect do
              apply_association(comment, "commentable", "has_any", [1], target_type: "photo")
            end.to raise_error(Scry::FilterError)
          end
          expect(target.comments.where(id: 1).ids).to eq([1])
          expect(apply_association(post, "comments", "has_any", [1], target_type: "post").ids).to eq([7])
          expect(apply_association(post, "comments", "has_any", [3], target_type: "post")).to be_empty
          expect(apply_association(post, "visible_comment", "has_any", [1], target_type: "post").ids).to eq([7])
          expect(apply_association(post, "visible_comment", "has_any", [4], target_type: "post")).to be_empty
        end
      end
    end
  end
end
