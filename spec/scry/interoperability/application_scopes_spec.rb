# frozen_string_literal: true

require_relative "support"
require_relative "temporary_table_support"

RSpec.describe "Application scope boundaries", :interoperability do
  it "preserves tenant and soft-delete scopes through aggregate OR and negation" do
    with_temporary_table("af_scope_owners", "id bigint PRIMARY KEY, tenant_id bigint NOT NULL, deleted_at timestamp, name varchar") do |owners|
      with_temporary_table("af_scope_children", "id bigint PRIMARY KEY, owner_id bigint NOT NULL, deleted_at timestamp") do |children|
        owner = temporary_model("InteroperabilityTemporary::ScopedOwner", owners)
        child = temporary_model("InteroperabilityTemporary::ScopedChild", children)
        owner.has_many :children, class_name: child.name, foreign_key: :owner_id
        owner.send(:default_scope, -> { where(tenant_id: 1, deleted_at: nil) })
        child.send(:default_scope, -> { where(deleted_at: nil) })
        owner.unscoped.create!(id: 1, tenant_id: 1, name: "Visible")
        owner.unscoped.create!(id: 2, tenant_id: 2, name: "Other tenant")
        owner.unscoped.create!(id: 3, tenant_id: 1, name: "Deleted", deleted_at: Time.current)
        owner.unscoped.create!(id: 4, tenant_id: 1, name: "Empty")
        child.unscoped.create!(id: 1, owner_id: 1)
        child.unscoped.create!(id: 2, owner_id: 1, deleted_at: Time.current)
        child.unscoped.create!(id: 3, owner_id: 2)
        child.unscoped.create!(id: 4, owner_id: 3)

        expect(apply(owner, aggregate("children", "eq", 1)).ids).to eq([1])
        expect(apply(owner, association("children", "has_any", [2]))).to be_empty
        expect(apply(owner, aggregate("children", "eq", 1), property("name", "eq", "Other tenant"), predicate: "or").ids).to eq([1])
        expect(apply(owner.order(:id).limit(1), aggregate("children", "eq", 1), negate: true).ids).to eq([4])
      end
    end
  end

  it "preserves the selected child for an association with a per-owner limit" do
    with_temporary_table("af_limited_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table("af_limited_children", "id bigint PRIMARY KEY, owner_id bigint NOT NULL") do |children|
        owner = temporary_model("InteroperabilityTemporary::LimitedOwner", owners)
        child = temporary_model("InteroperabilityTemporary::LimitedChild", children)
        owner.has_many :latest_children, -> { order(id: :desc).limit(1) }, class_name: child.name, foreign_key: :owner_id
        record = owner.create!(id: 1)
        child.create!(id: 1, owner_id: record.id)
        child.create!(id: 2, owner_id: record.id)

        expect(record.latest_children.ids).to eq([2])
        expect(apply(owner, association("latest_children", "has_any", [2])).ids).to eq([1])
        expect(apply(owner, association("latest_children", "has_any", [1]))).to be_empty
      end
    end
  end

  it "aggregates a field from the selected row of a per-owner limited association" do
    with_temporary_table("af_limited_field_owners", "id bigint PRIMARY KEY") do |owners|
      with_temporary_table("af_limited_field_children", "id bigint PRIMARY KEY, owner_id bigint NOT NULL, amount integer NOT NULL") do |children|
        owner = temporary_model("InteroperabilityTemporary::LimitedFieldOwner", owners)
        child = temporary_model("InteroperabilityTemporary::LimitedFieldChild", children)
        owner.has_many :latest_children, -> { order(id: :desc).limit(1) }, class_name: child.name, foreign_key: :owner_id
        record = owner.create!(id: 1)
        child.create!(id: 1, owner_id: record.id, amount: 3)
        child.create!(id: 2, owner_id: record.id, amount: 7)

        expect(apply(owner, aggregate("latest_children", "eq", 7, property: "amount", aggregate: "sum")).ids)
          .to eq([record.id])
      end
    end
  end
end
