require 'rails_helper'

RSpec.describe 'Model-level permission' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end
  end

  it 'defaults to allowed when no rules exist' do
    expect(User.model_allowed?(nil)).to eq(true)
  end

  it 'denies when a single deny rule is added' do
    User.add_model_permission { |_ctx| false }
    User.scry_permissions.clear_caches!
    expect(User.model_allowed?(nil)).to eq(false)
  end

  it 'allows when a single allow rule is added' do
    User.add_model_permission { |_ctx| true }
    User.scry_permissions.clear_caches!
    expect(User.model_allowed?(nil)).to eq(true)
  end

  it 'uses the last non-nil decision when multiple rules are added' do
    User.add_model_permission { |_ctx| false }
    User.add_model_permission { |_ctx| nil }
    User.add_model_permission { |_ctx| true }
    User.scry_permissions.clear_caches!
    expect(User.model_allowed?(nil)).to eq(true)
  end

  it 'treats nil as no-decision (ignored)' do
    User.add_model_permission { |_ctx| nil }
    User.scry_permissions.clear_caches!
    expect(User.model_allowed?(nil)).to eq(true)
  end

  it 'warns and denies on invalid return values (non true/false/nil) — fail-closed' do
    expect(Rails.logger).to receive(:warn).with(a_string_including('invalid model permission')).at_least(:once)
    User.add_model_permission { |_ctx| 'bad' }
    User.scry_permissions.clear_caches!
    expect(User.model_allowed?(nil)).to eq(false)
  end
end
