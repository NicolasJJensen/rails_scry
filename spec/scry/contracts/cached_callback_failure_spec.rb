# frozen_string_literal: true

require "rails_helper"

RSpec.describe "cached permission callback failures" do
  around do |example|
    original_permissions = User.scry_permissions.deep_dup(klass: User)
    Scry.configuration.with_temporary_settings do |config|
      config.callback_error_policy = :match_none
      config.invalid_filter_policy = :skip
      example.run
    end
  ensure
    User.scry_permissions = original_permissions
    Scry.clear_thread_caches!
  end

  it "does not turn a discovery callback failure into a skipped filter" do
    callback_calls = 0
    User.add_filter_permission(:properties) do |_context|
      callback_calls += 1
      raise "permission lookup failed"
    end
    user = create(:user, first_name: "Cached failure")
    context = Object.new
    filter = {
      type: "group",
      predicate: "and",
      filters: [{ type: "property", property: "first_name", predicate: "eq", args: [user.first_name] }]
    }

    User.filter_capabilities(context)

    result = Scry.filter_records_by(records: User.all, filter:, context:)

    expect(result.relation).to be_none
    expect(callback_calls).to eq(1)
    expect(result.diagnostics.map(&:code)).to eq([:callback_error])
  end
end
