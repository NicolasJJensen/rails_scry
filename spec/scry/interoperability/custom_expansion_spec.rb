# frozen_string_literal: true

require_relative "support"

RSpec.describe "Custom property DSL expansion", :interoperability do
  it "normalizes JSON definitions including nested groups" do
    selected = create(:user, first_name: "Selected")
    other = create(:user, first_name: "Other")
    definition = JSON.parse(JSON.generate(group(group(property("first_name", "eq", "Selected")))))
    User.add_custom_property_filter(type: :boolean) { {selected: definition} }
    scope = User.where(id: [selected.id, other.id])

    expect(apply(scope, property("selected", "eq_true")).ids).to eq([selected.id])
    expect(apply(scope, property("selected", "eq_false")).ids).to eq([other.id])
    expect(definition.keys).to all(be_a(String))
  end

  it "reports malformed expanded definitions at the custom property's path" do
    User.add_custom_property_filter(type: :boolean) { {broken: {"type" => "group", "predicate" => "and", "filters" => "invalid"}} }
    result = Scry.filter_records_by(records: User, filter: group(group(property("broken", "eq_true"))))

    expect(result.diagnostics.length).to eq(1)
    expect(result.diagnostics.first.path).to eq([:filters, 0, :filters, 0, :filters])
    expect(result.diagnostics.first.message).to include("non-array :filters")
  end

  it "requires custom-property permission callbacks to return a Hash" do
    hash_like = Struct.new(:entries) do
      def to_h
        entries
      end
    end
    User.add_custom_property_filter { hash_like.new({selected: group}) }

    expect { User.scry_permissions.allowed_custom_property_filters(nil) }
      .to raise_error(Scry::FilterError, /custom property filter must return a Hash/)
  end

  it "treats a nil custom-property permission callback as an empty map" do
    User.add_custom_property_filter { nil }

    expect(User.scry_permissions.allowed_custom_property_filters(nil)).to eq({})
  end

  it "keeps inherited custom-property definitions when a child adds another Hash definition" do
    stub_const("CustomPropertyInheritanceParent", Class.new(User))
    CustomPropertyInheritanceParent.add_custom_property_filter { {parent_flag: group} }
    stub_const("CustomPropertyInheritanceChild", Class.new(CustomPropertyInheritanceParent))
    CustomPropertyInheritanceChild.add_custom_property_filter { {child_flag: group} }

    expect(CustomPropertyInheritanceChild.scry_permissions.allowed_custom_property_filters(nil).keys)
      .to contain_exactly(:parent_flag, :child_flag)
  end
end
