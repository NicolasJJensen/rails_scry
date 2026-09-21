# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

RSpec.describe "built gem package", :packaging do
  let(:project_root) { File.expand_path("../../..", __dir__) }
  let(:gemspec_path) { File.join(project_root, "rails_scry.gemspec") }

  def run_ruby(*args)
    # RSpec may itself run under Bundler. Remove its auto-setup hooks so the
    # child cannot preload the checkout's copy of Scry.
    Open3.capture2e(
      { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil },
      RbConfig.ruby,
      *args
    )
  end

  it "contains every runtime, locale, metadata, and license file" do
    specification = Gem::Specification.load(gemspec_path)
    expect(specification.runtime_dependencies.map(&:name)).to contain_exactly("activerecord", "activesupport")

    Dir.mktmpdir("rails-scry-package") do |root|
      gem_path = File.join(root, "scry.gem")
      output, status = run_ruby("-S", "gem", "build", gemspec_path, "--output", gem_path)
      expect(status.success?).to be(true), output

      contents = Gem::Package.new(gem_path).contents
      expected = [
        "README.md",
        "CHANGELOG.md",
        "LICENSE.txt",
        *Dir.glob(File.join(project_root, "lib/**/*.rb")).map { |path| path.delete_prefix("#{project_root}/") },
        *Dir.glob(File.join(project_root, "config/locales/**/*.{rb,yml}")).map { |path| path.delete_prefix("#{project_root}/") }
      ]

      expect(contents).to include(*expected)
    end
  end

  it "installs and requires the package outside the checkout" do
    Dir.mktmpdir("rails-scry-install") do |root|
      gem_path = File.join(root, "scry.gem")
      install_dir = File.join(root, "gems")
      output, status = run_ruby("-S", "gem", "build", gemspec_path, "--output", gem_path)
      expect(status.success?).to be(true), output

      output, status = run_ruby(
        "-S", "gem", "install", gem_path,
        "--install-dir", install_dir,
        "--no-document",
        "--ignore-dependencies"
      )
      expect(status.success?).to be(true), output

      version = Gem::Specification.load(gemspec_path).version
      installed_lib = File.join(install_dir, "gems", "rails_scry-#{version}", "lib")
      source = <<~RUBY
        require "rails_scry"
        loaded = $LOADED_FEATURES.find { |feature| feature.end_with?("/rails_scry.rb") }
        installed_root = #{File.realpath(install_dir).inspect}
        abort("loaded from checkout: \#{loaded}") unless loaded && File.realpath(loaded).start_with?(installed_root)
        abort("missing configuration") unless Scry.respond_to?(:configuration)
        abort("missing ActiveRecord dependency") unless defined?(ActiveRecord::Relation)
      RUBY
      output, status = run_ruby("-I", installed_lib, "-e", source)
      expect(status.success?).to be(true), output
    end
  end
end
