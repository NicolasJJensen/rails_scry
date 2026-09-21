# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "support"

RSpec.describe "Reviewed extension contracts", interoperability: true do
  class ReviewExtensionFilter < Scry::Filters::Base
    def apply
      success(@scope)
    end
  end

  describe "custom property definitions" do
    def replace_custom_property_permissions(&block)
      User.reset_filter_permissions(:custom_property_filters)
      User.add_custom_property_filter(&block)
    end

    def custom_property_error
      yield
      raise "expected custom property definition to fail"
    rescue Scry::FilterError => error
      error
    end

    it "rejects invalid property keys with a redacted FilterError" do
      secret = "private-property-key"
      replace_custom_property_permissions do
        { Object.new.tap { |key| key.define_singleton_method(:inspect) { secret } } => property("first_name", "eq", "Ada") }
      end

      error = custom_property_error { User.custom_property_filters }
      expect(error.message).to match(/custom property key must be a name/)
      expect(error.message).not_to include(secret, "NoMethodError")
    end

    it "rejects unsupported metadata keys rather than silently discarding them" do
      replace_custom_property_permissions do
        { vip: { filter: property("first_name", "eq", "Ada"), internal_note: "private-note" } }
      end

      error = custom_property_error { User.custom_property_filters }
      expect(error.message).to match(/unsupported custom property metadata key/)
      expect(error.message).not_to include("private-note")
    end

    it "validates metadata types without exposing values or internal exceptions" do
      secret = "private-type-value"
      invalid_type = Object.new.tap { |value| value.define_singleton_method(:inspect) { secret } }
      replace_custom_property_permissions do
        { vip: { filter: property("first_name", "eq", "Ada"), type: invalid_type, label: Object.new } }
      end

      error = custom_property_error { User.filter_predicate_permissions }
      expect(error.message).to match(/custom property metadata/)
      expect(error.message).not_to include(secret, "NoMethodError")
    end

    it "validates predicate tokens without exposing values or internal exceptions" do
      secret = "private-predicate-value"
      invalid_predicate = Object.new.tap { |value| value.define_singleton_method(:inspect) { secret } }
      replace_custom_property_permissions do
        { vip: { filter: property("first_name", "eq", "Ada"), type: :boolean, predicates: [invalid_predicate] } }
      end

      error = custom_property_error { User.filter_predicate_permissions }
      expect(error.message).to match(/custom property predicates must contain names/)
      expect(error.message).not_to include(secret, "NoMethodError")
    end

    it "rejects malformed expanded filter definitions before execution" do
      replace_custom_property_permissions { { vip: { filter: ["not", "a", "filter"], type: :boolean } } }

      expect { User.custom_property_filters }
        .to raise_error(Scry::FilterError, /custom property filter definition must be a Hash/)
    end

    it "preserves programming errors raised inside the extension callback" do
      programming_error = NoMethodError.new("extension callback bug")
      replace_custom_property_permissions { raise programming_error }

      expect { User.custom_property_filters }
        .to raise_error { |error| expect(error).to equal(programming_error) }
    end
  end

  describe "configuration snapshots" do
    it "returns a frozen filter mapping snapshot and keeps registration on the validated path" do
      config = Scry.configuration
      snapshot = config.filter_class_mappings

      expect(snapshot).to be_frozen
      expect { snapshot[:bypass] = ReviewExtensionFilter }.to raise_error(FrozenError)

      config.register_filter(:review_extension, ReviewExtensionFilter)
      expect(config.filter_class_mappings[:review_extension]).to eq(ReviewExtensionFilter)
      expect(snapshot).not_to have_key(:review_extension)
    end

    it "defaults invalid filters to skip and validates every supported policy" do
      config = Scry.configuration
      expect(config.invalid_filter_policy).to eq(:skip)

      %i[skip raise match_none].each do |policy|
        config.invalid_filter_policy = policy.to_s
        expect(config.invalid_filter_policy).to eq(policy)
      end

      expect { config.invalid_filter_policy = :permit }.to raise_error(ArgumentError, /invalid_filter_policy/)
    end

    it "copies invalid_filter_policy into temporary settings" do
      Scry.configuration.invalid_filter_policy = :match_none

      Scry.configuration.with_temporary_settings do |temporary|
        expect(temporary.invalid_filter_policy).to eq(:match_none)
      end
    end
  end

  describe "registry lifecycle" do
    it "warms registry caches while preserving preparation-time registration" do
      registry = Scry::TypeRegistry.new
      registry.register(:textual, :string)
      registry.warm!

      expect(registry.by_group(:textual)).to include(:string)
      expect { registry.register(:textual, :text) }.not_to raise_error
      expect(registry.by_group(:textual)).to include(:string, :text)
    end

    it "warms both aggregate and predicate registries after initialization" do
      boot_configuration = Scry::Configuration.global_instance
      expect(boot_configuration.predicate_registry).to be_warmed
      expect(boot_configuration.aggregate_registry).to be_warmed
    end

    it "supports a reloadable custom filter registered from to_prepare" do
      Dir.mktmpdir("rails-scry-reload-extension") do |root|
        extension = File.join(root, "reloadable_review_filter.rb")
        File.write(extension, <<~RUBY)
          class ReloadableReviewFilter < Scry::Filters::Base
            def apply = @scope
          end
        RUBY
        source = <<~RUBY
          require "rails"
          require "active_record"
          require "rails_scry"

          extension = #{extension.dump}
          class ReviewContractApplication < Rails::Application
            config.eager_load = false
            config.cache_classes = false
            config.logger = Logger.new(nil)
            config.autoload_paths << #{root.dump}
          end
          ReviewContractApplication.config.to_prepare do
            Scry.configuration.register_filter(:reloadable_review, ReloadableReviewFilter)
          end
          ReviewContractApplication.initialize!
          first = Scry.configuration.filter_class_mappings.fetch(:reloadable_review)
          ReviewContractApplication.reloader.reload!
          second = Scry.configuration.filter_class_mappings.fetch(:reloadable_review)
          abort "extension did not reload" if first.equal?(second)
          puts "reloadable-extension-ok"
        RUBY

        output, status = Open3.capture2e(
          { "RUBYLIB" => File.expand_path("../../../lib", __dir__) },
          RbConfig.ruby, "-e", source
        )

        expect(status).to be_success, output
        expect(output).to include("reloadable-extension-ok")
      end
    end
  end
end
