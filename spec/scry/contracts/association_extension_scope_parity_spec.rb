# frozen_string_literal: true

require "rails_helper"

RSpec.describe "association extension scope parity" do
  before(:all) do
    Arel::Predications.module_eval do
      define_method(:has_two_candidates) do |value|
        query = Scry::AssociationQuery.for_attribute(self)
        rows = query.matching(value)
        query.owner_membership(rows.group(*query.parent_keys).having(Arel.star.count.gteq(2)))
      end
    end unless Arel::Predications.method_defined?(:has_two_candidates)

    Arel::Predications.module_eval do
      define_method(:has_candidate_account) do |value|
        Scry::AssociationQuery.for_attribute(self).has_any(value)
      end
    end unless Arel::Predications.method_defined?(:has_candidate_account)

    Scry.install_arel_extensions!
  end

  around do |example|
    permissions = User.scry_permissions.deep_dup(klass: User)
    scopes = Email.scry_scopes
    Scry.configuration.with_temporary_settings do |config|
      config.register_predicate(:has_two_candidates, types: [:many_association], applies_to: [:association], compounds: false) do |attribute, value|
        attribute.has_two_candidates(value)
      end
      User.add_filter_permission(:property_predicates) { {emails: [:has_two_candidates]} }
      User.add_filter_permission(:predicates, list_type: :includelist) { [:has_two_candidates] }
      example.run
    end
  ensure
    User.scry_permissions = permissions
    User.scry_permissions.clear_caches!
    Email.scry_scopes = scopes
  end

  it "preserves nested scoping, child authorization, and the aliased owner source" do
    allowed = create(:account)
    denied = create(:account)
    matching = create(:user)
    wrong_scope = create(:user)
    wrong_nested = create(:user)
    first = create(:email, account: allowed, address: "included-one@example.test")
    second = create(:email, account: allowed, address: "included-two@example.test")
    denied_email = create(:email, account: denied, address: "included-three@example.test")
    excluded = create(:email, account: allowed, address: "excluded@example.test")
    matching.emails << [first, second]
    wrong_scope.emails << [first, denied_email]
    wrong_nested.emails << [first, excluded]
    Email.add_filter_scope { |context| where(account_id: context.fetch(:account_id)) }

    source = User.arel_table.alias("association_extension_users")
    records = User.unscoped.from(source).select(source[Arel.star])
      .where(source[:id].in([matching.id, wrong_scope.id, wrong_nested.id]))
    result = Scry.filter_records_by(
      records:,
      context: {account_id: allowed.id},
      filter: {
        type: "group", predicate: "and", filters: [{
          type: "association", association: "emails", predicate: "has_two_candidates", args: [[first.id, second.id]],
          scoping: {
            type: "group", predicate: "and", filters: [
              {type: "property", property: "address", predicate: "starts_with", args: ["included"]}
            ]
          }
        }]
      }
    )

    expect(result).to be_success
    expect(result.relation.ids).to eq([matching.id])
  end

  it "preserves those constraints when the registration dispatches to the Arel method" do
    Scry.configuration.register_predicate(
      :has_two_candidates, types: [:many_association], applies_to: [:association], compounds: false, arel_predicate: :has_two_candidates
    )
    allowed = create(:account)
    denied = create(:account)
    matching = create(:user)
    denied_owner = create(:user)
    first = create(:email, account: allowed, address: "included-one@example.test")
    second = create(:email, account: allowed, address: "included-two@example.test")
    denied_email = create(:email, account: denied, address: "included-three@example.test")
    matching.emails << [first, second]
    denied_owner.emails << [first, denied_email]
    Email.add_filter_scope { |context| where(account_id: context.fetch(:account_id)) }

    source = User.arel_table.alias("association_extension_method_users")
    result = Scry.filter_records_by(
      records: User.unscoped.from(source).select(source[Arel.star]).where(source[:id].in([matching.id, denied_owner.id])),
      context: {account_id: allowed.id},
      filter: {
        type: "group", predicate: "and", filters: [{
          type: "association", association: "emails", predicate: "has_two_candidates", args: [[first.id, second.id]],
          scoping: {type: "group", predicate: "and", filters: [
            {type: "property", property: "address", predicate: "starts_with", args: ["included"]}
          ]}
        }]
      }
    )

    expect(result).to be_success
    expect(result.relation.ids).to eq([matching.id])
  end

  it "prepares a single-association Arel method for direct and DSL dispatch" do
    Scry.configuration.register_predicate(
      :has_candidate_account, types: [:single_association], applies_to: [:association], compounds: false, arel_predicate: :has_candidate_account
    )
    allowed = create(:account)
    denied = create(:account)
    matching = create(:user, account: allowed)
    other = create(:user, account: denied)
    User.add_filter_permission(:property_predicates) { {account: [:has_candidate_account]} }

    direct = User.where(id: [matching.id, other.id]).where(User.arel_table[:account].has_candidate_account([allowed.id]))
    dsl = Scry.filter_records_by(
      records: User.where(id: [matching.id, other.id]), context: nil,
      filter: {type: "group", predicate: "and", filters: [{
        type: "association", association: "account", predicate: "has_candidate_account", args: [[allowed.id]]
      }]}
    )

    expect(direct.ids).to eq([matching.id])
    expect(dsl).to be_success
    expect(dsl.relation.ids).to eq([matching.id])
  end

  it "prepares Arel association arguments exactly once" do
    received = []
    Scry.configuration.register_predicate(
      :has_candidate_account_prepared,
      types: [:single_association], applies_to: [:association], compounds: false,
      arel_predicate: :has_candidate_account,
      prepare_arguments: lambda { |args|
        received << args
        [args.first.to_i]
      }
    )
    allowed = create(:account)
    matching = create(:user, account: allowed)
    other = create(:user)
    User.add_filter_permission(:property_predicates) { {account: [:has_candidate_account_prepared]} }

    result = Scry.filter_records_by(
      records: User.where(id: [matching.id, other.id]),
      filter: {type: "group", predicate: "and", filters: [{
        type: "association", association: "account", predicate: "has_candidate_account_prepared", args: [allowed.id.to_s]
      }]}
    )

    expect(result.relation.ids).to eq([matching.id])
    expect(received).to eq([[allowed.id.to_s]])
  end

  it "applies association value transforms once for Arel and custom predicates" do
    transformed = []
    config = Scry.configuration
    config.register_predicate(
      :transformed_account_arel,
      types: [:single_association], applies_to: [:association], compounds: false,
      arel_predicate: :has_candidate_account
    )
    config.register_predicate(:transformed_account_custom, types: [:single_association], applies_to: [:association], compounds: false) do |attribute, value|
      attribute.has_candidate_account(value)
    end
    allowed = create(:account)
    matching = create(:user, account: allowed)
    User.add_filter_permission(:property_predicates) do
      {account: [:transformed_account_arel, :transformed_account_custom]}
    end
    User.add_filter_transform(:account, on: :value) do |value|
      transformed << value
      value
    end

    %i[transformed_account_arel transformed_account_custom].each do |predicate|
      result = Scry.filter_records_by(
        records: User.where(id: matching.id),
        filter: {type: "group", predicate: "and", filters: [{
          type: "association", association: "account", predicate:, args: [[allowed.id]]
        }]}
      )
      expect(result.relation.ids).to eq([matching.id])
    end

    expect(transformed).to eq([allowed.id, allowed.id])
  end
end
