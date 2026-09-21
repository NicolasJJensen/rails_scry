# frozen_string_literal: true

require "rails_helper"

RSpec.describe "removed compatibility surfaces" do
  around do |example|
    original = User.scry_permissions.deep_dup(klass: User)
    example.run
  ensure
    User.scry_permissions = original
    User.scry_permissions.clear_caches!
    Scry.clear_thread_caches!
  end

  it "rejects callable custom-property definitions" do
    User.add_custom_property_filter do
      { legacy: ->(_scope) { raise "legacy custom property" } }
    end

    expect { User.filter_capabilities }.to raise_error(Scry::FilterError, /Hash/)
  end
end
