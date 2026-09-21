# frozen_string_literal: true

require "rails_helper"

RSpec.describe "predicate argument preparation" do
  around do |example|
    Scry.configuration.with_temporary_settings { example.run }
  end

  def apply(predicate, args, records: User)
    Scry.filter_records_by(
      records:,
      filter: {type: :property, property: :first_name, predicate:, args:}
    )
  end

  before do
    Arel::Predications.module_eval do
      define_method(:prepared_optional_equal) do |value, enabled = true|
        enabled ? eq(value) : not_eq(value)
      end
    end unless Arel::Predications.method_defined?(:prepared_optional_equal)
  end

  it "lets a host prepare Ruby operands while preserving optional controls" do
    received = []
    Scry.configuration.register_predicate(
      :prepared_optional_equal,
      types: [:textual],
      compounds: false,
      arel_predicate: :prepared_optional_equal,
      prepare_arguments: lambda { |args|
        received << args
        [args.first.to_s, *args.drop(1)]
      }
    )
    matching = create(:user, first_name: "Ada")
    other = create(:user, first_name: "Grace")

    expect(apply(:prepared_optional_equal, ["Ada", false], records: User.where(id: [matching.id, other.id])).relation.ids).to contain_exactly(other.id)
    expect(received.fetch(0)).to eq(["Ada", false])
  end

  it "reports an invalid prepared argument list without leaking a TypeError" do
    Scry.configuration.register_predicate(
      :invalid_prepared_equal,
      types: [:textual],
      compounds: false,
      arel_predicate: :eq,
      prepare_arguments: ->(_args) { :not_an_array }
    )

    result = apply(:invalid_prepared_equal, ["Ada"])

    expect(result).to be_failed
    expect(result.diagnostics.map(&:code)).to include(:invalid_prepared_arguments)
  end

  it "rejects Arel nodes returned by Ruby argument preparation" do
    Scry.configuration.register_predicate(
      :arel_prepared_equal,
      types: [:textual],
      compounds: false,
      arel_predicate: :eq,
      prepare_arguments: ->(_args) { [Arel.sql("users.first_name")] }
    )
    User.add_filter_permission(:property_predicates) { {first_name: [:arel_prepared_equal]} }
    User.scry_permissions.clear_caches!

    Scry.configuration.invalid_filter_policy = :raise
    Scry.configuration.callback_error_policy = :raise
    expect { apply(:arel_prepared_equal, ["Ada"]) }
      .to raise_error(Scry::FilterError, /predicate argument preparation must return Ruby values/)
  end
end
