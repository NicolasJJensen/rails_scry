# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

namespace :package do
  desc "Build, install, and require the gem from a temporary directory"
  RSpec::Core::RakeTask.new(:smoke) do |task|
    task.pattern = "spec/scry/interoperability/packaging_spec.rb"
  end
end

require "rubocop/rake_task"

desc "Run correctness-focused static analysis"
RuboCop::RakeTask.new(:lint) do |task|
  task.options = ["--config", ".rubocop-lint.yml"]
end

desc "Run the complete RuboCop style and quality suite"
RuboCop::RakeTask.new(:rubocop)

task default: %i[spec lint]

namespace :db do
  def load_dummy_app!
    ENV["RAILS_ENV"] = "test"
    require_relative "spec/dummy/config/environment"
  end

  desc "Create and migrate the test database"
  task :setup do
    load_dummy_app!
    ActiveRecord::Tasks::DatabaseTasks.create_current
    ActiveRecord::MigrationContext.new(
      Rails.root.join("db/migrate")
    ).migrate
  end

  desc "Drop the test database"
  task :drop do
    load_dummy_app!
    ActiveRecord::Tasks::DatabaseTasks.drop_current
  end

  desc "Reset the test database (drop + setup)"
  task reset: [:drop, :setup]
end
