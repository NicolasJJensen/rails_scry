# frozen_string_literal: true

require_relative "support"
require_relative "temporary_table_support"

# rubocop:disable Metrics/BlockLength
RSpec.describe "Adapter and key compatibility contracts", interoperability: true do
  it "executes native PostgreSQL range and network operators against a temporary table" do
    skip "requires PostgreSQL" unless ActiveRecord::Base.connection.adapter_name.downcase.include?("postgresql")

    table_name = "af_native_contract_#{SecureRandom.hex(5)}"
    with_temporary_table(
      table_name,
      "id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, " \
        "period daterange NOT NULL, network inet NOT NULL, tags text[] NOT NULL"
    ) do |table|
      model = temporary_model("InteroperabilityTemporary::NativeRecord", table)
      row = model.create!(
        period: Date.new(2026, 1, 1)..Date.new(2026, 1, 10),
        network: "10.20.0.0/24", tags: %w[ruby rails]
      )

      contained_period = Date.new(2026, 1, 2)..Date.new(2026, 1, 5)
      expect(apply(model.where(id: row.id), property("period", "range_contains", contained_period)).ids)
        .to eq([row.id])
      expect(apply(model.where(id: row.id), property("network", "inet_contains", "10.20.0.7")).ids)
        .to eq([row.id])
    end
  end

  it "wraps a scalar array operand as a one-element PostgreSQL array" do
    skip "requires PostgreSQL" unless ActiveRecord::Base.connection.adapter_name.downcase.include?("postgresql")

    table_name = "af_array_contract_#{SecureRandom.hex(5)}"
    with_temporary_table(
      table_name,
      "id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tags text[] NOT NULL"
    ) do |table|
      model = temporary_model("InteroperabilityTemporary::ArrayRecord", table)
      row = model.create!(tags: %w[ruby rails])

      expect(apply(model.where(id: row.id), property("tags", "array_contains", "ruby")).ids)
        .to eq([row.id])
      expect(apply(model.where(id: row.id), property("tags", "array_contains", ["java"]))).to be_empty
    end
  end

  it "uses a nondefault primary key and reflection keys for a temporary model" do
    parent_table = "af_key_parent_#{SecureRandom.hex(5)}"
    child_table = "af_key_child_#{SecureRandom.hex(5)}"
    with_temporary_table(parent_table, "code varchar PRIMARY KEY, label varchar NOT NULL") do |parent_name|
      with_temporary_table(
        child_table,
        "id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, parent_code varchar NOT NULL"
      ) do |child_name|
        parent = temporary_model("InteroperabilityTemporary::KeyParent", parent_name)
        child = temporary_model("InteroperabilityTemporary::KeyChild", child_name)
        parent.primary_key = "code"
        parent.has_many :children, class_name: child.name, foreign_key: :parent_code, primary_key: :code
        child.belongs_to :parent, class_name: parent.name, foreign_key: :parent_code, primary_key: :code

        record = parent.create!(code: "P-001", label: "keyed")
        child_record = child.create!(parent_code: record.code)

        expect(apply(parent.where(code: record.code), association("children", "has_any", [child_record.id])).ids)
          .to eq([record.code])
      end
    end
  end

  it "preserves an ActiveRecord relation whose FROM clause uses an Arel table alias" do
    record = create(:user, first_name: "Aliased source")
    source = User.arel_table.alias("users_source")
    relation = User.from(source).where(source[:id].eq(record.id)).select(source[Arel.star])

    expect(relation.ids).to eq([record.id])
    expect(apply(relation, property("first_name", "eq", "Aliased source")).ids).to eq([record.id])
  end

  it "reports unsupported polymorphic associations through the FilterError contract" do
    table_name = "af_polymorphic_contract_#{SecureRandom.hex(5)}"
    with_temporary_table(
      table_name,
      "id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, " \
        "commentable_type varchar NOT NULL, commentable_id bigint NOT NULL"
    ) do |table|
      model = temporary_model("InteroperabilityTemporary::PolymorphicComment", table)
      model.belongs_to :commentable, polymorphic: true
      Scry.configuration.invalid_filter_policy = :raise

      expect do
        apply(model, association("commentable", "has_any", [1]))
      end.to raise_error(Scry::FilterError)
    end
  end

  it "filters composite primary keys while preserving the ordered key map" do
    table_name = "af_composite_contract_#{SecureRandom.hex(5)}"
    with_temporary_table(
      table_name,
      "tenant_id bigint NOT NULL, code varchar NOT NULL, PRIMARY KEY (tenant_id, code)"
    ) do |table|
      model = temporary_model("InteroperabilityTemporary::CompositeRecord", table)
      model.primary_key = %w[tenant_id code]
      first = model.create!(tenant_id: 7, code: "A")
      second = model.create!(tenant_id: 8, code: "A")

      expect(apply(model, property("tenant_id", "eq", 7)).pluck(:tenant_id, :code))
        .to eq([[first.tenant_id, first.code]])
      expect(Scry::Compatibility.canonical_keys(model, [[second.tenant_id, second.code]]))
        .to eq([[8, "A"]])
    end
  end
end
# rubocop:enable Metrics/BlockLength
