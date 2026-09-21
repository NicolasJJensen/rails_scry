# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] = "test"
require_relative "dummy/config/environment"

require "rspec/rails"
require "factory_bot_rails"
require "timecop"

# Run migrations on the test database
ActiveRecord::Migration.maintain_test_schema!

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods

  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.after(:each) do
    Thread.current[:scry_caches]&.clear
  end
end

# Tell FactoryBot where the factories live (gem root, not dummy app)
FactoryBot.definition_file_paths = [File.expand_path("factories", __dir__)]
FactoryBot.find_definitions
