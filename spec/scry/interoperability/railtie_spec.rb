# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# rubocop:disable Metrics/BlockLength
RSpec.describe "Railtie integration" do
  it "does not register the package locale more than once during Rails boot" do
    source = <<~RUBY
      require "rails"
      require "active_record/railtie"
      require "rails_scry"

      class RailtieContractApplication < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(nil)
      end

      RailtieContractApplication.initialize!
      locale = File.expand_path("config/locales/scry.en.yml", #{File.expand_path("../../..", __dir__).inspect})
      count = I18n.load_path.count { |path| File.expand_path(path) == locale }
      abort("locale registered \#{count} times") unless count == 1
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", source)
    expect(status).to be_success, output
  end

  it "registers the package locale when loaded without Rails" do
    source = <<~RUBY
      require "active_record"
      require "rails_scry"

      locale = File.expand_path("config/locales/scry.en.yml", #{File.expand_path("../../..", __dir__).inspect})
      count = I18n.load_path.count { |path| File.expand_path(path) == locale }
      abort("standalone locale registered \#{count} times") unless count == 1
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", source)
    expect(status).to be_success, output
  end
end
# rubocop:enable Metrics/BlockLength
