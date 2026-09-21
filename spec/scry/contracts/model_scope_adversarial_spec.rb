# frozen_string_literal: true

require "rails_helper"
require_relative "../interoperability/temporary_table_support"

# rubocop:disable Metrics/BlockLength
RSpec.describe "mandatory model scope adversarial contracts", :interoperability do
  def apply_filter(records, child, context: nil, negate: false)
    result = Scry.filter_records_by(
      records:,
      context:,
      filter: { type: "group", predicate: "and", filters: [child], negate: }
    )
    result.respond_to?(:relation) ? result.relation : result
  end

  def association(name, predicate, value, **options)
    { type: "association", association: name, predicate:, args: [value], **options }
  end

  def aggregate(name, predicate, value, **options)
    { type: "aggregate", association: name, aggregate: "count", predicate:, args: [value], **options }
  end

  it "contains empty groups and unscoped custom filters within a derived caller source" do
    with_temporary_table(
      "af_scope_adversarial_roots",
      "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, name varchar NOT NULL"
    ) do |table|
      model = temporary_model("ModelScopeAdversarial::Root", table)
      model.add_filter_scope { |context| model.where(tenant_id: context.fetch(:tenant_id)) }
      model.create!(id: 1, tenant_id: 1, name: "allowed")
      model.create!(id: 2, tenant_id: 2, name: "denied")

      custom = Class.new(Scry::Filters::Base) do
        def apply
          success(@model.unscoped)
        end
      end
      Scry.configuration.register_filter(:model_scope_unscoped_adversarial, custom)

      source = model.select(:id, :tenant_id, :name).arel.as("scope_adversarial_source")
      records = model.unscoped.from(source).select(source[Arel.star])
      context = { tenant_id: 1 }

      empty = Scry.filter_records_by(
        records:,
        context:,
        filter: { type: "group", predicate: "and", filters: [] }
      )
      empty_relation = empty.respond_to?(:relation) ? empty.relation : empty
      expect(empty_relation.ids).to eq([1])
      expect(apply_filter(records, { type: "model_scope_unscoped_adversarial" }, context:).ids).to eq([1])
      expect(apply_filter(records, { type: "model_scope_unscoped_adversarial" }, context:, negate: true)).to be_empty
    end
  end

  it "authorizes association rows before applying each owner's limit" do
    with_temporary_table("af_scope_adversarial_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_scope_adversarial_ranked_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, position integer NOT NULL, visible boolean NOT NULL"
      ) do |children|
        owner = temporary_model("ModelScopeAdversarial::RankedOwner", owners)
        child = temporary_model("ModelScopeAdversarial::RankedChild", children)
        owner.has_many :latest_children, -> { order(position: :desc, id: :desc).limit(1) },
                       class_name: child.name, foreign_key: :owner_id
        child.add_filter_scope { |context| child.where(visible: context.fetch(:visible)) }

        record = owner.create!(id: 1)
        allowed = child.create!(id: 1, owner_id: record.id, position: 1, visible: true)
        denied = child.create!(id: 2, owner_id: record.id, position: 2, visible: false)
        context = { visible: true }

        expect(apply_filter(owner.all, association("latest_children", "has_any", [allowed.id]), context:).ids)
          .to eq([record.id])
        expect(apply_filter(owner.all, association("latest_children", "has_any", [denied.id]), context:))
          .to be_empty
        expect(apply_filter(owner.all, aggregate("latest_children", "eq", 1), context:).ids).to eq([record.id])
      end
    end
  end

  it "applies the same-model scope to both aliases of a self-referential through association" do
    with_temporary_table(
      "af_scope_adversarial_nodes",
      "id bigint PRIMARY KEY, parent_id bigint, visible boolean NOT NULL"
    ) do |nodes|
      node = temporary_model("ModelScopeAdversarial::Node", nodes)
      node.has_many :children, class_name: node.name, foreign_key: :parent_id
      node.has_many :grandchildren, through: :children, source: :children
      node.add_filter_scope { |context| node.where(visible: context.fetch(:visible)) }

      root = node.create!(id: 1, visible: true)
      visible_child = node.create!(id: 2, parent_id: root.id, visible: true)
      hidden_child = node.create!(id: 3, parent_id: root.id, visible: false)
      visible_grandchild = node.create!(id: 4, parent_id: visible_child.id, visible: true)
      hidden_target = node.create!(id: 5, parent_id: visible_child.id, visible: false)
      behind_hidden_intermediate = node.create!(id: 6, parent_id: hidden_child.id, visible: true)
      context = { visible: true }

      expect(apply_filter(node.where(id: root.id), association("grandchildren", "has_any", [visible_grandchild.id]),
                          context:).ids)
        .to eq([root.id])
      expect(apply_filter(node.where(id: root.id), association("grandchildren", "has_any", [hidden_target.id]),
                          context:))
        .to be_empty
      expect(apply_filter(node.where(id: root.id),
                          association("grandchildren", "has_any", [behind_hidden_intermediate.id]), context:))
        .to be_empty
    end
  end

  it "applies the selected polymorphic target's mandatory scope" do
    with_temporary_table(
      "af_scope_adversarial_comments",
      "id bigint PRIMARY KEY, commentable_type varchar NOT NULL, commentable_id bigint NOT NULL"
    ) do |comments|
      with_temporary_table(
        "af_scope_adversarial_posts",
        "id bigint PRIMARY KEY, tenant_id bigint NOT NULL"
      ) do |posts|
        comment = temporary_model("ModelScopeAdversarial::Comment", comments)
        post = temporary_model("ModelScopeAdversarial::Post", posts)
        comment.belongs_to :commentable, polymorphic: true
        comment.add_filter_targets(:commentable, post: post)
        comment.add_filter_permission(:associations, list_type: :includelist) { [:commentable] }
        post.add_filter_scope { |context| post.where(tenant_id: context.fetch(:tenant_id)) }

        allowed = post.create!(id: 1, tenant_id: 1)
        denied = post.create!(id: 2, tenant_id: 2)
        allowed_comment = comment.create!(id: 1, commentable: allowed)
        denied_comment = comment.create!(id: 2, commentable: denied)
        context = { tenant_id: 1 }

        filter = association("commentable", "has_any", [allowed.id, denied.id], target_type: "post")
        expect(apply_filter(comment.where(id: [allowed_comment.id, denied_comment.id]), filter, context:).ids)
          .to eq([allowed_comment.id])
      end
    end
  end

  it "treats hidden children as absent in zero and negated aggregate branches" do
    with_temporary_table("af_scope_adversarial_count_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_scope_adversarial_count_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, visible boolean NOT NULL"
      ) do |children|
        owner = temporary_model("ModelScopeAdversarial::CountOwner", owners)
        child = temporary_model("ModelScopeAdversarial::CountChild", children)
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        child.add_filter_scope { |context| child.where(visible: context.fetch(:visible)) }
        visible_owner = owner.create!(id: 1)
        hidden_owner = owner.create!(id: 2)
        child.create!(id: 1, owner_id: visible_owner.id, visible: true)
        child.create!(id: 2, owner_id: hidden_owner.id, visible: false)
        context = { visible: true }

        zero = aggregate("children", "eq", 0)
        expect(apply_filter(owner.all, zero, context:).ids).to eq([hidden_owner.id])
        expect(apply_filter(owner.all, aggregate("children", "gt", 0), context:, negate: true).ids)
          .to eq([hidden_owner.id])
      end
    end
  end

  it "fails closed under every invalid-filter policy when a mandatory scope callback fails" do
    with_temporary_table("af_scope_adversarial_failures", "id bigint PRIMARY KEY") do |table|
      model = temporary_model("ModelScopeAdversarial::Failure", table)
      model.create!(id: 1)
      model.add_filter_scope { raise "host authorization failed" }

      %i[skip match_none].each do |policy|
        Scry.configuration.with_temporary_settings do |config|
          config.invalid_filter_policy = policy
          result = Scry.filter_records_by(
            records: model.all,
            context: { tenant_id: 1 },
            filter: { type: "group", predicate: "and", filters: [] }
          )

          expect(result).to be_failed
          expect(result.relation).to be_empty
          expect(result.diagnostics).to include(have_attributes(category: :scope_error, code: :scope_error))
        end
      end

      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise

        expect do
          Scry.filter_records_by(
            records: model.all,
            context: { tenant_id: 1 },
            filter: { type: "group", predicate: "and", filters: [] }
          )
        end.to raise_error(Scry::FilterError) { |error|
          expect(error.result).to be_failed
          expect(error.result.relation).to be_empty
          expect(error.result.diagnostics).to include(have_attributes(category: :scope_error, code: :scope_error))
        }
      end
    end
  end

  it "passes context through public filtering and fails closed when direct native Arel has none" do
    with_temporary_table("af_scope_adversarial_arel_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_scope_adversarial_arel_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, visible boolean NOT NULL"
      ) do |children|
        owner = temporary_model("ModelScopeAdversarial::ArelOwner", owners)
        child = temporary_model("ModelScopeAdversarial::ArelChild", children)
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        child.add_filter_scope do |context|
          raise "authorization context required" unless context

          child.where(visible: context.fetch(:visible))
        end
        first = owner.create!(id: 1)
        second = owner.create!(id: 2)
        allowed = child.create!(id: 1, owner_id: first.id, visible: true)
        denied = child.create!(id: 2, owner_id: second.id, visible: false)

        expect(apply_filter(owner.all, association("children", "has_any", [allowed.id, denied.id]),
                            context: { visible: true }).ids).to eq([first.id])

        Scry.install_arel_extensions!
        expect { owner.arel_table[:children].has_any([allowed.id, denied.id]) }
          .to raise_error(Scry::ModelScopeError, /callback failed/)
      end
    end
  end

  it "rejects nil and wrong-model scope results without exposing the caller relation" do
    with_temporary_table("af_scope_adversarial_invalid_results", "id bigint PRIMARY KEY") do |table|
      base = temporary_model("ModelScopeAdversarial::InvalidResultBase", table)
      base.create!(id: 1)
      nil_model = Class.new(base)
      stub_const("ModelScopeAdversarial::NilResult", nil_model)
      nil_model.add_filter_scope { nil }
      wrong_model = Class.new(base)
      stub_const("ModelScopeAdversarial::WrongResult", wrong_model)
      wrong_model.add_filter_scope { User.all }

      [nil_model, wrong_model].each do |model|
        result = Scry.filter_records_by(
          records: model.all,
          filter: { type: "group", predicate: "and", filters: [] }
        )
        expect(result).to be_failed
        expect(result.relation).to be_empty
        expect(result.diagnostics).to include(have_attributes(category: :scope_error))
      end
    end
  end

  it "preserves compound identity through the full filtering entry point" do
    with_temporary_table(
      "af_scope_adversarial_compounds",
      "tenant_id bigint NOT NULL, code varchar NOT NULL, visible boolean NOT NULL, " \
      "PRIMARY KEY (tenant_id, code)"
    ) do |table|
      model = temporary_model("ModelScopeAdversarial::Compound", table)
      model.primary_key = %w[tenant_id code]
      model.add_filter_scope { |context| model.where(visible: context.fetch(:visible)) }
      model.create!(tenant_id: 1, code: "same", visible: true)
      model.create!(tenant_id: 2, code: "same", visible: false)

      result = Scry.filter_records_by(
        records: model.all,
        context: { visible: true },
        filter: { type: "group", predicate: "and", filters: [] }
      )
      expect(result.relation.pluck(:tenant_id, :code)).to eq([[1, "same"]])
    end
  end

  it "intersects inherited named and block scopes with same-column caller constraints" do
    with_temporary_table(
      "af_scope_adversarial_conjunctions",
      "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, active boolean NOT NULL"
    ) do |table|
      parent = temporary_model("ModelScopeAdversarial::ConjunctionParent", table)
      parent.define_singleton_method(:tenant_scope) do |context|
        where(tenant_id: context.fetch(:tenant_id))
      end
      parent.add_filter_scope :tenant_scope
      parent.add_filter_scope { |context| where(active: context.fetch(:active)) }
      child = Class.new(parent)
      stub_const("ModelScopeAdversarial::ConjunctionChild", child)
      child.create!(id: 1, tenant_id: 1, active: true)
      child.create!(id: 2, tenant_id: 1, active: false)
      child.create!(id: 3, tenant_id: 2, active: true)
      context = { tenant_id: 1, active: true }
      empty_group = { type: "group", predicate: "and", filters: [] }

      expect(Scry.filter_records_by(records: child.all, filter: empty_group, context:).relation.ids)
        .to eq([1])
      expect(Scry.filter_records_by(
        records: child.where(tenant_id: 2), filter: empty_group, context:
      ).relation)
        .to be_empty
    end
  end

  it "keeps association authorization lazy and set-based for all owners" do
    with_temporary_table("af_scope_adversarial_set_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "af_scope_adversarial_set_children",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, visible boolean NOT NULL"
      ) do |children|
        owner = temporary_model("ModelScopeAdversarial::SetOwner", owners)
        child = temporary_model("ModelScopeAdversarial::SetChild", children)
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        callback_calls = 0
        authorized_relations = []
        child.add_filter_scope do |context|
          callback_calls += 1
          child.where(visible: context.fetch(:visible)).tap { |relation| authorized_relations << relation }
        end
        records = (1..3).map { |id| owner.create!(id:) }
        records.each { |record| child.create!(id: record.id, owner_id: record.id, visible: true) }

        result = apply_filter(owner.all, association("children", "has_any", child.ids), context: { visible: true })
        select_sql = []
        subscriber = lambda do |_name, _started, _finished, _id, payload|
          select_sql << payload[:sql] if payload[:sql].match?(/\ASELECT\b/i) && payload[:name] != "SCHEMA"
        end
        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          expect(result.ids).to eq(records.map(&:id))
        end

        expect(callback_calls).to eq(1)
        expect(authorized_relations).to all(satisfy { |relation| !relation.loaded? })
        expect(select_sql.length).to eq(1)
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
