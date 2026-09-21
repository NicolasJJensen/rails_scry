# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'bundler'
require 'rbconfig'

RSpec.describe 'Standalone adapter command' do
  let(:root) { File.expand_path('../../..', __dir__) }

  def run_adapter(environment = {})
    gem_path = Gem.path.join(File::PATH_SEPARATOR)
    Bundler.with_unbundled_env do
      Open3.capture3({
        'GEM_PATH' => gem_path,
        'BUNDLE_GEMFILE' => File.join(root, 'gemfiles', 'adapters.gemfile'),
        'SCRY_ADAPTER' => 'sqlite3',
        'RUBYLIB' => nil,
        'RAILS_VERSION' => ENV.fetch('RAILS_VERSION', '8.1')
      }.merge(environment),
                    RbConfig.ruby, 'script/compatibility.rb', chdir: root)
    end
  end

  it 'loads this checkout without an installed rails_scry gem or a RUBYLIB override' do
    output, error, status = run_adapter
    expect(status).to be_success, "#{output}\n#{error}"
    expect(output).to include('sqlite3 association and aggregate contracts: PASS')
  end

  it 'rejects an unavailable requested ActiveRecord line instead of using the newest installed line' do
    output, error, status = run_adapter('RAILS_VERSION' => '0.0')
    expect(status).not_to be_success
    expect("#{output}\n#{error}").to match(/activerecord.*0\.0|0\.0.*activerecord/)
  end
end
