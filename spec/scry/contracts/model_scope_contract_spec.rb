# frozen_string_literal: true

require "rails_helper"
require_relative "../interoperability/temporary_table_support"
require_relative "../interoperability/support"

RSpec.describe "mandatory model scope contracts", :interoperability do
  around do |example|
    models = [ApplicationRecord, User, Email, Job, ScheduleAssignment, Technician, Organisation]
    models << InteroperabilityModels::Organisation if defined?(InteroperabilityModels::Organisation)
    original_scopes = models.to_h do |model|
      [model, model.respond_to?(:scry_scopes) ? model.scry_scopes : []]
    end
    models.each { |model| model.scry_scopes = [].freeze if model.respond_to?(:scry_scopes=) }
    example.run
  ensure
    original_scopes&.each { |model, scopes| model.scry_scopes = scopes }
  end

  def relation_from(result)
    result.respond_to?(:relation) ? result.relation : result
  end

  def apply(records, definition, context: nil)
    relation_from(Scry.filter_records_by(records:, filter: definition, context:))
  end

  def group(child, negate: false)
    {type: "group", predicate: "and", filters: [child], negate:}
  end

  def property(name, value)
    {type: "property", property: name, predicate: "eq", args: [value]}
  end

  def association(name, predicate, value)
    {type: "association", association: name, predicate:, args: [value]}
  end

  def aggregate(name, predicate, value, **options)
    {type: "aggregate", association: name, aggregate: "count", predicate:, args: [value], **options}
  end

  it "inherits registered scopes and intersects them with the caller relation" do
    parent = Class.new(User)
    stub_const("ModelScopeContracts::ParentUser", parent)
    parent.add_filter_scope { |context| where(active: context.fetch(:active)) }
    child = Class.new(parent)
    stub_const("ModelScopeContracts::ChildUser", child)
    allowed = create(:user, active: true)
    denied = create(:user, active: false)

    expect(Scry::ModelScope.apply(child.where(id: [allowed.id, denied.id]), context: {active: true}).ids)
      .to eq([allowed.id])
  end

  it "applies the root scope to direct filters and negated groups" do
    User.add_filter_scope { |context| where(organisation_id: context.fetch(:organisation_id)) }
    allowed_organisation = create(:organisation)
    denied_organisation = create(:organisation)
    allowed = create(:user, organisation: allowed_organisation, first_name: "Allowed")
    create(:user, organisation: denied_organisation, first_name: "Denied")

    records = User.where(id: User.ids)
    context = {organisation_id: allowed_organisation.id}

    expect(apply(records, group(property("first_name", "Allowed")), context:).ids).to eq([allowed.id])
    expect(apply(records, group(property("first_name", "nobody"), negate: true), context:).ids).to eq([allowed.id])
  end

  it "applies the child scope to association membership and nested filters" do
    Email.add_filter_scope { |context| where(account_id: context.fetch(:account_id)) }
    allowed_account = create(:account)
    denied_account = create(:account)
    owner = create(:user)
    denied_owner = create(:user)
    allowed = create(:email, account: allowed_account, address: "shared@example.com")
    denied = create(:email, account: denied_account, address: "shared@example.com")
    owner.emails << allowed
    denied_owner.emails << denied
    context = {account_id: allowed_account.id}

    expect(apply(User.where(id: [owner.id, denied_owner.id]), group(association("emails", "has_any", [allowed.id, denied.id])), context:).ids)
      .to eq([owner.id])

    nested = {type: "association", association: "emails", predicate: "has_any", scoping: group(property("address", "shared@example.com"))}
    expect(apply(User.where(id: [owner.id, denied_owner.id]), group(nested), context:).ids).to eq([owner.id])
  end

  it "applies the child scope before aggregate counts and zero handling" do
    Email.add_filter_scope { |context| where(account_id: context.fetch(:account_id)) }
    allowed_account = create(:account)
    denied_account = create(:account)
    visible_owner = create(:user)
    hidden_owner = create(:user)
    visible_owner.emails << create(:email, account: allowed_account)
    hidden_owner.emails << create(:email, account: denied_account)
    context = {account_id: allowed_account.id}
    records = User.where(id: [visible_owner.id, hidden_owner.id])

    expect(apply(records, group(aggregate("emails", "eq", 1)), context:).ids).to eq([visible_owner.id])
    expect(apply(records, group(aggregate("emails", "eq", 0)), context:).ids).to eq([hidden_owner.id])
  end

  it "does not reduce has_all candidates to the authorized subset" do
    Email.add_filter_scope { |context| where(account_id: context.fetch(:account_id)) }
    allowed_account = create(:account)
    denied_account = create(:account)
    owner = create(:user)
    allowed = create(:email, account: allowed_account)
    denied = create(:email, account: denied_account)
    owner.emails << [allowed, denied]
    context = {account_id: allowed_account.id}

    expect(apply(User.where(id: owner.id), group(association("emails", "has_all", [allowed.id, denied.id])), context:).ids)
      .to be_empty
  end

  it "applies the child scope before a per-owner association limit" do
    owner_model = Class.new(User)
    stub_const("ModelScopeContracts::LimitedOwner", owner_model)
    email_model = Class.new(Email)
    stub_const("ModelScopeContracts::LimitedEmail", email_model)
    owner_model.has_many :latest_emails, -> { order(created_at: :desc).limit(1) },
      class_name: email_model.name, foreign_key: :account_id, primary_key: :account_id
    email_model.add_filter_scope { |context| where(address: context.fetch(:address)) }
    account = create(:account)
    owner = create(:user, account:)
    visible = create(:email, account:, address: "visible@example.com", created_at: 1.day.ago)
    create(:email, account:, address: "hidden@example.com", created_at: Time.current)
    context = {address: visible.address}

    expect(apply(owner_model.where(id: owner.id), group(association("latest_emails", "has_any", [visible.id])), context:).ids)
      .to eq([owner.id])
  end

  it "applies mandatory scopes to the target and join model of a through association" do
    technician = Technician.create!(name: "Scoped technician")
    allowed_job = Job.create!(title: "Allowed")
    denied_job = Job.create!(title: "Denied")
    allowed_assignment = ScheduleAssignment.create!(technician:, job: allowed_job)
    ScheduleAssignment.create!(technician:, job: denied_job)
    Job.add_filter_scope { |context| where(id: context.fetch(:job_id)) }
    ScheduleAssignment.add_filter_scope { |context| where(id: context.fetch(:assignment_id)) }
    context = {job_id: allowed_job.id, assignment_id: allowed_assignment.id}

    expect(apply(Technician.where(id: technician.id), group(association("jobs", "has_any", [allowed_job.id])), context:).ids)
      .to eq([technician.id])
    expect(apply(Technician.where(id: technician.id), group(association("jobs", "has_any", [denied_job.id])), context:).ids)
      .to be_empty

    context = context.merge(assignment_id: -1)
    expect(apply(Technician.where(id: technician.id), group(association("jobs", "has_any", [allowed_job.id])), context:).ids)
      .to be_empty
  end

  it "fails closed when a scope callback raises or returns another model" do
    relation_model = Class.new(User)
    stub_const("ModelScopeContracts::InvalidUser", relation_model)
    records = relation_model.where(id: create(:user).id)
    relation_model.add_filter_scope { raise "scope failed" }

    expect { Scry::ModelScope.apply(records, context: nil) }
      .to raise_error(Scry::ModelScopeError, /scope callback failed/)

    wrong_model = Class.new(User)
    stub_const("ModelScopeContracts::WrongUser", wrong_model)
    wrong_model.add_filter_scope { Email.all }
    expect { Scry::ModelScope.apply(wrong_model.all, context: nil) }
      .to raise_error(Scry::ModelScopeError, /must return.*relation/i)
  end

  it "returns a failed empty result for scope errors under the skip policy" do
    User.add_filter_scope { raise "scope failed" }
    record = create(:user)

    %i[skip].each do |policy|
      Scry.configuration.with_temporary_settings do |settings|
        settings.invalid_filter_policy = policy
        result = Scry.filter_records_by(
          records: User.where(id: record.id),
          filter: group(property("first_name", record.first_name))
        )

        expect(result).to be_failed
        expect(result.relation).to be_empty
        expect(result.diagnostics.map(&:code)).to include(:scope_error)
      end
    end
  end

  it "applies a model scope through a self-referential association alias" do
    model = InteroperabilityModels::Organisation
    model.scry_scopes = [].freeze
    model.add_filter_scope { |context| where(location: context.fetch(:location)) }
    parent = model.create!(name: "Parent", location: "visible")
    visible_child = model.create!(name: "Visible", parent_id: parent.id, location: "visible")
    hidden_child = model.create!(name: "Hidden", parent_id: parent.id, location: "hidden")
    context = {location: "visible"}

    expect(apply(model.where(id: parent.id), group(association("children", "has_any", [visible_child.id])), context:).ids)
      .to eq([parent.id])
    expect(apply(model.where(id: parent.id), group(association("children", "has_any", [hidden_child.id])), context:).ids)
      .to be_empty
  end

  it "preserves composite-key identity when it applies a mandatory scope" do
    with_temporary_table(
      "af_model_scope_composites",
      "tenant_id bigint NOT NULL, code varchar NOT NULL, visible boolean NOT NULL, PRIMARY KEY (tenant_id, code)"
    ) do |table|
      model = temporary_model("ModelScopeContracts::Composite", table)
      model.primary_key = %w[tenant_id code]
      model.add_filter_scope { |context| where(visible: context.fetch(:visible)) }
      model.create!(tenant_id: 1, code: "same", visible: true)
      model.create!(tenant_id: 2, code: "same", visible: false)

      expect(Scry::ModelScope.apply(model.all, context: {visible: true}).pluck(:tenant_id, :code))
        .to eq([[1, "same"]])
    end
  end
end
