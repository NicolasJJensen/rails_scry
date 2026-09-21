# frozen_string_literal: true

require_relative "lib/scry/version"

Gem::Specification.new do |spec|
  spec.name = "rails_scry"
  spec.version = Scry::VERSION
  spec.authors = ["Nicolas J Jensen"]
  spec.email = ["nicolasjensen9@gmail.com"]

  spec.summary = "Extensible ActiveRecord filtering with a JSON DSL, type-safe predicates, and fine-grained permissions"
  spec.description = "Translates JSON filter definitions into optimized ActiveRecord queries. " \
                     "Supports property, association, aggregate, and group filters " \
                     "with permission-controlled access per model, per attribute, per predicate."
  spec.homepage = "https://github.com/NicolasJJensen/rails_scry"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues"
  }

  # Keep the package independent of the checkout index. A release build must
  # include new source and locale files before they are staged or committed.
  # The patterns are deliberately bounded to package-owned files so a symlink
  # elsewhere in the checkout cannot pull an arbitrary tree into the gem.
  package_patterns = [
    "lib/*.rb",
    "lib/scry/*.rb",
    "lib/scry/filters/*.rb",
    "lib/scry/middleware/*.rb",
    "lib/scry/predications/*.rb",
    "sig/*.rbs",
    "config/locales/*.rb",
    "config/locales/*.yml",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]
  spec.files = package_patterns.flat_map do |pattern|
    Dir.glob(File.join(__dir__, pattern)).filter_map do |path|
      relative_path = path.delete_prefix("#{__dir__}/")
      relative_path if File.file?(path) && !File.symlink?(path)
    end
  end.uniq.sort
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "activerecord",  ">= 7.1", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1", "< 9.0"
end
