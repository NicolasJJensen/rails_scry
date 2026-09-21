# frozen_string_literal: true

require "rails_helper"

RSpec.describe "association predicate extension contract" do
  before(:all) do
    Arel::Predications.module_eval do
      define_method(:has_at_least_two) do |value|
        query = Scry::AssociationQuery.for_attribute(self)
        query.owner_count_at_least(value, minimum: 2)
      end
    end unless Arel::Predications.method_defined?(:has_at_least_two)

    Scry.install_arel_extensions!
  end

  around do |example|
    original = User.scry_permissions.deep_dup(klass: User)
    Scry.configuration.with_temporary_settings do |config|
      config.register_predicate(:has_at_least_two, types: [:many_association], applies_to: [:association], compounds: false) do |attribute, value|
        attribute.has_at_least_two(value)
      end
      User.add_filter_permission(:property_predicates) { {emails: [:has_at_least_two]} }
      User.add_filter_permission(:predicates, list_type: :includelist) { [:has_at_least_two] }
      example.run
    end
  ensure
    User.scry_permissions = original
    User.scry_permissions.clear_caches!
  end

  def owners_matching(node)
    Scry.filter_records_by(
      records: User,
      context: nil,
      filter: {type: "group", predicate: "and", filters: [node]}
    )
  end

  it "uses the same built-in method on a direct Arel attribute for IDs, relations, and record arrays" do
    matching = create(:user)
    other = create(:user)
    first = create(:email)
    second = create(:email)
    matching.emails << [first, second]
    other.emails << first
    attribute = User.arel_table[:emails]
    scope = User.where(id: [matching.id, other.id])

    expect(scope.where(attribute.has_any([first.id, second.id])).ids).to contain_exactly(matching.id, other.id)
    expect(scope.where(attribute.has_all(Email.where(id: [first.id, second.id]))).ids).to contain_exactly(matching.id)
    expect(scope.where(attribute.only_has_all([first, second])).ids).to contain_exactly(matching.id)
    expect(scope.where(attribute.has_at_least_two([first.id, second.id])).ids).to contain_exactly(matching.id)
  end

  it "treats non-positive cardinality thresholds as universally satisfied and rejects invalid thresholds" do
    query = Scry::AssociationQuery.for_attribute(User.arel_table[:emails])
    owners = User.where(id: create_list(:user, 2).map(&:id))

    expect(owners.where(query.owner_count_at_least([], minimum: 0)).ids).to contain_exactly(*owners.ids)
    expect(owners.where(query.owner_count_at_least([], minimum: -1)).ids).to contain_exactly(*owners.ids)
    [1.5, "2", Float::NAN, Float::INFINITY, nil].each do |minimum|
      expect { query.owner_count_at_least([], minimum:) }
        .to raise_error(Scry::FilterError, /cardinality minimum is invalid/)
    end
  end

  it "uses a host-defined Arel method unchanged through predicate registration and DSL scoping" do
    matching = create(:user)
    other = create(:user)
    first = create(:email, address: "included-one@example.test")
    second = create(:email, address: "included-two@example.test")
    excluded = create(:email, address: "excluded@example.test")
    matching.emails << [first, second]
    other.emails << [first, excluded]

    direct = User.where(id: [matching.id, other.id]).where(
      User.arel_table[:emails].has_at_least_two([first.id, second.id])
    )
    dsl = owners_matching(
      type: "association",
      association: "emails",
      predicate: "has_at_least_two",
      args: [[first.id, second.id]],
      scoping: {
        type: "group",
        predicate: "and",
        filters: [
          {type: "property", property: "address", predicate: "starts_with", args: ["included"]}
        ]
      }
    )

    expect(direct.ids).to contain_exactly(matching.id)
    expect(dsl).to be_success
    expect(dsl.relation.ids).to contain_exactly(matching.id)
    expect(Scry.configuration.predicate_registry.by_name(:has_at_least_two)).not_to have_key(:association_native)
  end

  it "allows a zero-operand association predicate to consume child scoping" do
    config = Scry.configuration
    config.register_predicate(:has_scoped_children, types: [:many_association], applies_to: [:association], compounds: false) do |attribute|
      Scry::AssociationQuery.for_attribute(attribute).owner_child_predicate(:not_eq, nil)
    end
    User.add_filter_permission(:property_predicates) { {emails: [:has_scoped_children]} }
    User.scry_permissions.clear_caches!

    matching = create(:user)
    excluded = create(:user)
    included_email = create(:email, address: "included-zero@example.test")
    excluded_email = create(:email, address: "excluded-zero@example.test")
    matching.emails << included_email
    excluded.emails << excluded_email

    result = owners_matching(
      type: "association",
      association: "emails",
      predicate: "has_scoped_children",
      args: [],
      scoping: {
        type: "group",
        predicate: "and",
        filters: [{type: "property", property: "address", predicate: "starts_with", args: ["included-zero"]}]
      }
    )

    expect(result).to be_success
    expect(result.relation.ids).to contain_exactly(matching.id)
  end

  it "keeps scoping out of optional and required predicate operands" do
    received = []
    config = Scry.configuration
    config.register_predicate(:optional_scoped_children, types: [:many_association], applies_to: [:association], compounds: false) do |attribute, value = :default|
      received << value
      Scry::AssociationQuery.for_attribute(attribute).owner_child_predicate(:not_eq, nil)
    end
    config.register_predicate(:required_scoped_children, types: [:many_association], applies_to: [:association], compounds: false) do |_attribute, _value|
      raise "required operand should not be supplied by scoping"
    end
    User.add_filter_permission(:property_predicates) do
      {emails: [:optional_scoped_children, :required_scoped_children]}
    end
    User.scry_permissions.clear_caches!

    matching = create(:user)
    excluded = create(:user)
    matching.emails << create(:email, address: "included-optional@example.test")
    excluded.emails << create(:email, address: "excluded-optional@example.test")
    scoping = {
      type: "group",
      predicate: "and",
      filters: [{type: "property", property: "address", predicate: "starts_with", args: ["included-optional"]}]
    }

    optional = owners_matching(
      type: "association", association: "emails", predicate: "optional_scoped_children", scoping:
    )
    required = owners_matching(
      type: "association", association: "emails", predicate: "required_scoped_children", scoping:
    )

    expect(optional).to be_success
    expect(optional.relation.ids).to contain_exactly(matching.id)
    expect(received).to eq([:default])
    expect(required).to be_failed
    expect(required.diagnostics.map(&:message)).to include(match(/expects 1 argument/))
  end

  it "keeps built-in scope-only association predicates on the prepared query" do
    matching = create(:user)
    excluded = create(:user)
    matching.emails << create(:email, address: "included-built-in@example.test")
    excluded.emails << create(:email, address: "excluded-built-in@example.test")
    scoping = {
      type: "group",
      predicate: "and",
      filters: [{type: "property", property: "address", predicate: "starts_with", args: ["included-built-in"]}]
    }

    result = owners_matching(
      type: "association", association: "emails", predicate: "has_any", scoping:
    )

    expect(result).to be_success
    expect(result.relation.ids).to contain_exactly(matching.id)
  end

  it "uses the reflection scope and child authorization for zero-operand candidates" do
    owner_model = Class.new(User)
    stub_const("AssociationPredicateExtension::ScopedOwner", owner_model)
    owner_model.has_many :included_emails, -> { where(address: "included-reflection@example.test") },
      through: :account, source: :emails

    original_scopes = Email.scry_scopes
    allowed_account = create(:account)
    excluded_account = create(:account)
    denied_account = create(:account)
    included_owner = create(:user, account: allowed_account)
    excluded_owner = create(:user, account: excluded_account)
    denied_owner = create(:user, account: denied_account)
    create(:email, account: allowed_account, address: "included-reflection@example.test")
    create(:email, account: excluded_account, address: "excluded-reflection@example.test")
    create(:email, account: denied_account, address: "included-reflection@example.test")
    Email.add_filter_scope { |context| where(account_id: context.fetch(:account_ids)) }

    result = Scry.filter_records_by(
      records: owner_model.where(id: [included_owner.id, excluded_owner.id, denied_owner.id]),
      context: {account_ids: [allowed_account.id, excluded_account.id]},
      filter: {type: "group", predicate: "and", filters: [{
        type: "association", association: "included_emails", predicate: "has_any", args: []
      }]}
    )

    expect(result).to be_success
    expect(result.relation.ids).to contain_exactly(included_owner.id)
  ensure
    Email.scry_scopes = original_scopes if original_scopes
  end

  it "gives direct Arel association predicates the same all-candidates default" do
    matching = create(:user)
    excluded = create(:user)
    first = create(:email)
    second = create(:email)
    matching.emails << [first, second]
    excluded.emails << first
    owners = User.where(id: [matching.id, excluded.id])
    attribute = User.arel_table[:emails]

    expect(owners.where(attribute.has_all).ids).to eq(
      owners.where(attribute.has_all(Email.all)).ids
    )
    expect(owners.where(attribute.only_has_any).ids).to eq(
      owners.where(attribute.only_has_any(Email.all)).ids
    )
    expect(owners.where(attribute.only_has_all).ids).to eq(
      owners.where(attribute.only_has_all(Email.all)).ids
    )
  end

  it "preserves a raw candidate query's duplicate rows until after its limit" do
    only_first = create(:user)
    both = create(:user)
    first = create(:email)
    second = create(:email)
    only_first.emails << first
    both.emails << [first, second]

    candidates = Email.joins(:users)
      .where(id: [first.id, second.id])
      .order(Email.arel_table[:id].asc)
      .limit(2)
      .select(:id)
      .arel

    result = User.where(id: [only_first.id, both.id]).where(
      User.arel_table[:emails].has_all(candidates)
    )

    # The raw query emits [first, first] before its limit. Deduplicate that
    # selected candidate set afterwards, so both owners satisfy has_all(first).
    expect(result.ids).to contain_exactly(only_first.id, both.id)

    cardinality = User.where(id: [only_first.id, both.id]).where(
      Scry::AssociationQuery.for_attribute(User.arel_table[:emails])
        .owner_count_at_least(candidates, minimum: 2)
    )
    expect(cardinality.ids).to be_empty
  end
end
