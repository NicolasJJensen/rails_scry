# frozen_string_literal: true

require "rails_helper"
require_relative "../interoperability/temporary_table_support"

RSpec.describe "default filter exclusions", :interoperability do
  def group(*filters)
    {type: :group, predicate: :and, filters:}
  end

  def property(name)
    {type: :property, property: name, predicate: :eq, args: ["value"]}
  end

  it "discovers real AR columns while excluding encrypted and belongs_to keys" do
    with_temporary_table("af_default_exclusion_owners", "id bigint PRIMARY KEY") do |owners_table|
      with_temporary_table(
        "af_default_exclusion_records",
        "id bigint PRIMARY KEY, owner_id bigint, secret_name varchar, password_digest varchar, plain_name varchar"
      ) do |records_table|
        owner = temporary_model("DefaultExclusions::Owner", owners_table)
        record = temporary_model("DefaultExclusions::Record", records_table)
        record.belongs_to :owner, class_name: owner.name, foreign_key: :owner_id
        record.encrypts :secret_name
        owner.create!(id: 1)
        record.create!(id: 1, owner_id: 1, password_digest: "hash", plain_name: "value")

        properties = record.scry_permissions.allowed_properties(nil)

        expect(properties).to include(:id, :password_digest, :plain_name)
        expect(properties).not_to include(:owner_id, :secret_name)
      end
    end
  end

  it "does not allow a permission includelist to restore excluded AR columns" do
    with_temporary_table("af_default_exclusion_permission_owners", "id bigint PRIMARY KEY") do |owners_table|
      with_temporary_table(
        "af_default_exclusion_permission_records",
        "id bigint PRIMARY KEY, owner_id bigint, secret_name varchar, password_digest varchar"
      ) do |records_table|
        owner = temporary_model("DefaultExclusions::PermissionOwner", owners_table)
        record = temporary_model("DefaultExclusions::PermissionRecord", records_table)
        record.belongs_to :owner, class_name: owner.name, foreign_key: :owner_id
        record.encrypts :secret_name
        record.add_filter_permission(:properties, list_type: :includelist) do
          [:owner_id, :secret_name]
        end

        expect(record.scry_permissions.allowed_properties(nil)).not_to include(:owner_id, :secret_name)

        %i[owner_id secret_name].each do |excluded_property|
          result = Scry.filter_records_by(records: record, filter: group(property(excluded_property)))

          expect(result.diagnostics).to contain_exactly(
            have_attributes(category: :permission_denied, code: :property_denied, path: [:filters, 0, :property])
          )
        end
      end
    end
  end
end
