# frozen_string_literal: true

require "rails_helper"
require_relative "../interoperability/support"
require_relative "../interoperability/temporary_table_support"

RSpec.describe "uniform custom filter scope contract", :interoperability do
  around do |example|
    Scry.configuration.with_temporary_settings do |config|
      original_scopes = User.scry_scopes
      example.run
    ensure
      User.scry_scopes = original_scopes
    end
  end

  it "keeps custom property pagination inside the caller's authorized relation" do
    custom_property = Class.new(Scry::Filters::Property) do
      def apply
        success(source_relation.order(source_attribute(:id).desc).limit(1))
      end
    end
    Scry.configuration.register_filter(:scoped_custom_property, custom_property)

    first = create(:user, first_name: "first")
    second = create(:user, first_name: "second")
    outside = create(:user, first_name: "outside")
    caller_relation = User.where(id: [first.id, second.id]).order(id: :asc)

    result = Scry.filter_records_by(
      records: caller_relation,
      filter: {
        type: :group,
        predicate: :and,
        filters: [{type: :scoped_custom_property}]
      }
    )

    expect(result).to be_success
    expect(result.relation.ids).to eq([second.id])
    expect(result.relation.ids).not_to include(outside.id)
  end

  it "lets an Association subclass delegate to super with caller ownership constraints" do
    custom_association = Class.new(Scry::Filters::Association) do
      def apply
        super
      end
    end
    Scry.configuration.register_filter(:scoped_custom_association, custom_association)

    matching = create(:user)
    other = create(:user)
    matching_email = create(:email)
    matching.emails << matching_email
    caller_relation = User.where(id: [matching.id, other.id]).order(id: :desc)

    result = Scry.filter_records_by(
      records: caller_relation,
      filter: {
        type: :group,
        predicate: :and,
        filters: [{
          type: :scoped_custom_association,
          association: :emails,
          predicate: :has_any,
          args: [[matching_email.id]]
        }]
      }
    )

    expect(result).to be_success
    expect(result.relation.ids).to eq([matching.id])
  end

  it "lets an Association subclass delegate to super from a grouped caller relation" do
    custom_association = Class.new(Scry::Filters::Association) do
      def apply
        super
      end
    end
    Scry.configuration.register_filter(:grouped_custom_association, custom_association)

    matching = create(:user)
    other = create(:user)
    first = create(:email)
    second = create(:email)
    matching.emails << [first, second]
    matching_scope = User.joins(:emails).where(id: [matching.id, other.id])
      .group("users.id").having("COUNT(emails.id) >= 2")

    result = Scry.filter_records_by(
      records: matching_scope,
      filter: {
        type: :group,
        predicate: :and,
        filters: [{
          type: :grouped_custom_association,
          association: :emails,
          predicate: :has_any,
          args: [[first.id, second.id]]
        }]
      }
    )

    expect(result).to be_success
    expect(result.relation.ids).to eq([matching.id])
  end

  it "lets a root Association subclass delegate to super from a grouped caller relation" do
    custom_association = Class.new(Scry::Filters::Association) do
      def apply
        super
      end
    end
    Scry.configuration.register_filter(:root_grouped_custom_association, custom_association)

    matching = create(:user)
    other = create(:user)
    first = create(:email)
    second = create(:email)
    matching.emails << [first, second]
    matching_scope = User.joins(:emails).where(id: [matching.id, other.id])
      .group("users.id").having("COUNT(emails.id) >= 2")

    result = Scry.filter_records_by(
      records: matching_scope,
      filter: {
        type: :root_grouped_custom_association,
        association: :emails,
        predicate: :has_any,
        args: [[first.id, second.id]]
      }
    )

    expect(result).to be_success
    expect(result.relation.ids).to eq([matching.id])
  end

  it "keeps grouped HAVING and per-owner association limits when a subclass calls super" do
    with_temporary_table("scope_extension_grouped_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "scope_extension_grouped_reviews",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, score integer NOT NULL"
      ) do |reviews|
        owner = temporary_model("ScopeExtension::Owner", owners)
        review = temporary_model("ScopeExtension::Review", reviews)
        owner.has_many :reviews, class_name: review.name, foreign_key: :owner_id
        owner.has_many :latest_reviews, -> { order(score: :desc, id: :asc).limit(1) },
                      class_name: review.name, foreign_key: :owner_id

        first = owner.create!(id: 1)
        second = owner.create!(id: 2)
        newest = review.create!(id: 10, owner_id: first.id, score: 10)
        review.create!(id: 9, owner_id: first.id, score: 9)
        second_latest = review.create!(id: 8, owner_id: second.id, score: 8)
        grouped = owner.joins(:reviews).group("scope_extension_grouped_owners.id")
          .having("MAX(scope_extension_grouped_reviews.score) >= 9")

        custom_association = Class.new(Scry::Filters::Association) do
          def apply
            super
          end
        end
        Scry.configuration.register_filter(:grouped_scope_association, custom_association)
        result = Scry.filter_records_by(
          records: grouped,
          filter: {
            type: :group,
            predicate: :and,
            filters: [{
              type: :grouped_scope_association,
              association: :latest_reviews,
              predicate: :has_any,
              args: [[newest.id]]
            }]
          }
        )

        expect(result).to be_success
        expect(result.relation.ids).to eq([first.id])
        expect(second_latest).to be_persisted
      end
    end
  end

  it "projects grouped owner keys correctly through an aliased caller source" do
    with_temporary_table("scope_extension_alias_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table(
        "scope_extension_alias_reviews",
        "id bigint PRIMARY KEY, owner_id bigint NOT NULL, score integer NOT NULL"
      ) do |reviews|
        owner = temporary_model("ScopeExtension::AliasOwner", owners)
        review = temporary_model("ScopeExtension::AliasReview", reviews)
        owner.has_many :reviews, class_name: review.name, foreign_key: :owner_id
        owner.has_many :latest_reviews, -> { order(score: :desc, id: :asc).limit(1) },
                      class_name: review.name, foreign_key: :owner_id

        first = owner.create!(id: 1)
        second = owner.create!(id: 2)
        newest = review.create!(id: 10, owner_id: first.id, score: 10)
        review.create!(id: 9, owner_id: first.id, score: 9)
        review.create!(id: 8, owner_id: second.id, score: 8)
        source = owner.arel_table.alias("scope_extension_alias_source")
        grouped = owner.from(source)
          .joins("INNER JOIN scope_extension_alias_reviews ON scope_extension_alias_reviews.owner_id = scope_extension_alias_source.id")
          .group("scope_extension_alias_source.id")
          .having("MAX(scope_extension_alias_reviews.score) >= 9")

        result = Scry.filter_records_by(
          records: grouped,
          filter: {
            type: :group,
            predicate: :and,
            filters: [{
              type: :association,
              association: :latest_reviews,
              predicate: :has_any,
              args: [[newest.id]]
            }]
          }
        )

        expect(result).to be_success
        expect(result.relation.map(&:id)).to eq([first.id])
        expect(second).to be_persisted
      end
    end
  end

  it "keeps root, nested, and negated custom relations inside aliased mandatory scope" do
    custom_filter = Class.new(Scry::Filters::Base) do
      def apply
        success(source_relation.where(source_attribute(:first_name).not_eq("excluded")).order(source_attribute(:id).asc).limit(1))
      end
    end
    Scry.configuration.register_filter(:scoped_custom_relation, custom_filter)
    User.add_filter_scope { where(active: true) }

    allowed = create(:user, first_name: "allowed", active: true)
    later = create(:user, first_name: "later", active: true)
    excluded = create(:user, first_name: "excluded", active: false)
    outside = create(:user, first_name: "outside", active: false)
    source = User.arel_table.alias("scoped_custom_users")
    caller_relation = User.unscoped.from(source).select(source[Arel.star])
      .where(source[:id].in([allowed.id, later.id, excluded.id, outside.id]))

    root = Scry.filter_records_by(
      records: caller_relation,
      context: nil,
      filter: {type: :scoped_custom_relation}
    )
    nested = Scry.filter_records_by(
      records: caller_relation,
      context: nil,
      filter: {type: :group, predicate: :and, filters: [{type: :scoped_custom_relation}]}
    )
    negated = Scry.filter_records_by(
      records: caller_relation,
      context: nil,
      filter: {type: :group, predicate: :and, negate: true, filters: [{type: :scoped_custom_relation}]}
    )

    expect(root.relation.ids).to eq([allowed.id])
    expect(nested.relation.ids).to eq([allowed.id])
    expect(negated.relation.ids).to eq([later.id])
  end
end
