require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'Consumer boot contracts' do
  it 'AF-01 registers association predicates when configured during Rails initialization' do
    Dir.mktmpdir('rails-scry-boot') do |root|
      source = <<~RUBY
        require 'rails'
        require 'active_record/railtie'
        require 'rails_scry'
        class ConsumerBootApp < Rails::Application
          config.root = #{root.inspect}
          config.eager_load = false
          config.logger = Logger.new(File::NULL)
          initializer 'consumer.filter_configuration', before: :load_config_initializers do
            Scry.configure { |c| c.invalid_filter_policy = :raise }
          end
        end
        ConsumerBootApp.initialize!
        expected = %i[has_any not_has_any has_all not_has_all only_has_any only_has_all]
        missing = expected - Scry.configuration.predicate_registry.names
        abort("Missing predicates: \#{missing.inspect}") unless missing.empty?
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', source)
      expect(status.success?).to be(true), output
    end
  end

  it 'initializes the core without Rails and does not patch Arel globally' do
    source = <<~RUBY
      require 'active_record'
      require 'rails_scry'
      abort('Rails loaded') if defined?(Rails)
      abort('Missing predicates') unless Scry.configuration.predicate_registry.names.include?(:has_any)
      abort('Global Arel mutation') if Arel::Predications.method_defined?(:has_any)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', source)
    expect(status.success?).to be(true), output
  end

  it 'registers association predicates for a normal consumer initializer as well' do
    Dir.mktmpdir('rails-scry-boot') do |root|
      source = <<~RUBY
        require 'rails'
        require 'active_record/railtie'
        require 'rails_scry'
        class ConsumerNormalBootApp < Rails::Application
          config.root = #{root.inspect}
          config.eager_load = false
          config.logger = Logger.new(File::NULL)
          initializer 'consumer.filter_configuration' do
            Scry.configure { |c| c.invalid_filter_policy = :raise }
          end
        end
        ConsumerNormalBootApp.initialize!
        expected = %i[has_any not_has_any has_all not_has_all only_has_any only_has_all]
        missing = expected - Scry.configuration.predicate_registry.names
        abort("Missing predicates: \#{missing.inspect}") unless missing.empty?
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', source)
      expect(status.success?).to be(true), output
    end
  end

  it 'boots standalone ActiveRecord without Rails or an adapter connection' do
    source = <<~RUBY
      require 'active_record'
      require 'rails_scry'
      abort('Rails loaded') if defined?(Rails)
      abort('ActiveRecord missing') unless defined?(ActiveRecord::Relation)
      abort('Filterable missing') unless Scry.const_defined?(:Filterable)
      abort('configuration missing') unless Scry.respond_to?(:configuration)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', source)
    expect(status.success?).to be(true), output
  end

  it 'leaves Arel extensions opt-in for standalone consumers' do
    source = <<~RUBY
      require 'active_record'
      require 'rails_scry'
      abort('Rails loaded') if defined?(Rails)
      abort('install API missing') unless Scry.respond_to?(:install_arel_extensions!)
      abort('extension unexpectedly installed') if Arel::Predications.method_defined?(:has_any)
      Scry.install_arel_extensions!
      abort('extension was not installed') unless Arel::Predications.method_defined?(:has_any)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', source)
    expect(status.success?).to be(true), output
  end
end
