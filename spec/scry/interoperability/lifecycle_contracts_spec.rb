# frozen_string_literal: true

require_relative "support"

RSpec.describe "Lifecycle and metadata contracts", interoperability: true do
  it "invalidates cached metadata for a known nonreloadable model on Rails prepare" do
    expect(User.filter_property_permissions).to include(:first_name)
    User.add_filter_permission(:properties, list_type: :blacklist) { [:first_name] }
    expect(User.filter_property_permissions).not_to include(:first_name)

    Rails.application.reloader.prepare!

    expect(User.filter_property_permissions).not_to include(:first_name)
    expect { apply(User.where(first_name: "stale"), property("first_name", "eq", "stale")) }
      .not_to raise_error
  end

  it "does not allow metadata mutation to alter enforcement state" do
    predicates = User.filter_predicate_permissions[:first_name]
    expect(predicates).to be_frozen
    expect { predicates << :synthetic_predicate }.to raise_error(FrozenError)
    expect(User.filter_predicate_permissions[:first_name]).not_to include(:synthetic_predicate)

    metadata = User.scry_permissions.predicate_metadata(nil)
    expect(metadata).to be_frozen
    expect(metadata[:eq]).to be_frozen
    original_label = metadata[:eq][:label]
    expect { metadata[:eq][:label] = "changed by consumer" }.to raise_error(FrozenError)
    expect(User.scry_permissions.predicate_metadata(nil)[:eq][:label]).to eq(original_label)
  end
end
