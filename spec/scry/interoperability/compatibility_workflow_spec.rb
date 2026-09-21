# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'bundler'

RSpec.describe 'Compatibility dependency isolation' do
  let(:root) { File.expand_path('../../..', __dir__) }
  let(:jobs) { YAML.load_file(File.join(root, '.github/workflows/compatibility.yml'))['jobs'] }

  it 'resolves each PostgreSQL matrix entry outside the development lockfile' do
    job = jobs.fetch('postgres-regression')
    template = job.fetch('env').fetch('BUNDLE_GEMFILE', 'Gemfile')
    job.fetch('strategy').fetch('matrix').fetch('include').each do |entry|
      path = template.gsub(/\$\{\{ matrix\.(\w+) \}\}/) { entry.fetch(Regexp.last_match(1)) }
      expect(path).not_to eq('Gemfile'), "Rails #{entry.fetch('rails')} reuses the development lockfile"
      expect(File).to exist(File.join(root, path))
    end
  end

  it 'selects an RSpec Rails line compatible with Rails 7.1' do
    job = jobs.fetch('postgres-regression')
    path = File.join(root, job.fetch('env').fetch('BUNDLE_GEMFILE'))
    previous = ENV['RAILS_VERSION']
    %w[7.1].each do |version|
      ENV['RAILS_VERSION'] = version
      dsl = Bundler::Dsl.new
      dsl.eval_gemfile(path)
      dependencies = dsl.dependencies.to_h { |dependency| [dependency.name, dependency.requirement] }
      expect(dependencies.fetch('rubocop')).to be_satisfied_by(Gem::Version.new('1.85.0'))
      expect(dependencies.fetch('json')).to be_satisfied_by(Gem::Version.new('2.20.0'))
      expect(dependencies.fetch('json')).not_to be_satisfied_by(Gem::Version.new('3.0.0'))
      expect(dependencies.fetch('rails')).to be_satisfied_by(Gem::Version.new("#{version}.0"))
      expect(dependencies.fetch('rspec-rails')).to be_satisfied_by(Gem::Version.new('6.1.0'))
      expect(dependencies.fetch('rspec-rails')).not_to be_satisfied_by(Gem::Version.new('7.0.0'))
    end
  ensure
    ENV['RAILS_VERSION'] = previous
  end

  it 'runs adapters through a bundle that includes their database driver' do
    job = jobs.fetch('adapter-core')
    gemfile = job.fetch('env').fetch('BUNDLE_GEMFILE', 'Gemfile')
    expect(gemfile).not_to eq('Gemfile')
    expect(File).to exist(File.join(root, gemfile))
    commands = job.fetch('steps').filter_map { |step| step['run'] }
    expect(commands).to include('bundle exec ruby script/compatibility.rb')
    expect(commands.grep(/gem install/)).to be_empty
  end

  it 'tests adapters on the minimum supported Ruby for each Rails line' do
    job = jobs.fetch('adapter-core')
    matrix = job.fetch('strategy').fetch('matrix')
    expected_pairs = {
      '7.1' => '3.1',
      '7.2' => '3.2',
      '8.0' => '3.3',
      '8.1' => '3.3'
    }

    entries = matrix.fetch('include')
    expected_pairs.to_a.product(%w[sqlite3 mysql2]).each do |(rails, ruby), adapter|
      expect(entries).to include(
        'rails' => rails,
        'ruby' => ruby,
        'adapter' => adapter
      )
    end
    expect(job.fetch('name')).to include('${{ matrix.ruby }}')
    expect(job.fetch('steps').find { |step| step['uses'] == 'ruby/setup-ruby@v1' }
      .fetch('with').fetch('ruby-version')).to eq('${{ matrix.ruby }}')
  end

  it 'requires native CTE support and excludes older Rails lines from CI' do
    specification = Gem::Specification.load(File.join(root, 'rails_scry.gemspec'))
    %w[activerecord activesupport].each do |name|
      requirement = specification.runtime_dependencies.find { |dependency| dependency.name == name }.requirement
      expect(requirement).not_to be_satisfied_by(Gem::Version.new('7.0.10'))
      expect(requirement).to be_satisfied_by(Gem::Version.new('7.1.0'))
    end
    %w[postgres-regression adapter-core].each do |name|
      entries = jobs.fetch(name).fetch('strategy').fetch('matrix').fetch('include')
      expect(entries.map { |entry| entry.fetch('rails') }.uniq).to contain_exactly('7.1', '7.2', '8.0', '8.1')
    end
  end

  it 'uses the same focused lint gate from the default rake task and CI' do
    rakefile = File.read(File.join(root, 'Rakefile'))
    expect(rakefile).to match(/RuboCop::RakeTask\.new\(:lint\)/)
    expect(rakefile).to include('"--config", ".rubocop-lint.yml"')
    expect(rakefile).to match(/RuboCop::RakeTask\.new\(:rubocop\)/)
    expect(rakefile).to match(/task default: .*\blint\b/)

    lint_job = jobs.fetch('lint')
    commands = lint_job.fetch('steps').filter_map { |step| step['run'] }
    expect(commands).to include('bundle exec rake lint')
  end
end
