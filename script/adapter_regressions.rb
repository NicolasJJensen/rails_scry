#!/usr/bin/env ruby
# frozen_string_literal: true

gem 'activerecord', "~> #{ENV.fetch('RAILS_VERSION', '8.1')}.0"
require 'logger'
require 'active_record'
require 'rspec/autorun'
require_relative '../lib/rails_scry'
require_relative '../spec/support/interoperability_boundaries'

adapter = ENV.fetch('SCRY_ADAPTER', 'sqlite3')
connection = case adapter
when 'sqlite3'
  {adapter: adapter, database: ':memory:'}
when 'postgresql'
  {adapter: adapter, database: ENV.fetch('PGDATABASE', 'scry_test')}
when 'mysql2'
  {adapter: adapter, host: ENV.fetch('MYSQL_HOST', '127.0.0.1'), port: ENV.fetch('MYSQL_PORT', '3306'),
   username: ENV.fetch('MYSQL_USER', 'root'), password: ENV.fetch('MYSQL_PASSWORD', 'root'),
   database: ENV.fetch('MYSQL_DATABASE', 'scry_test')}
else
  abort 'SCRY_ADAPTER must be sqlite3, mysql2, or postgresql'
end
ActiveRecord::Base.establish_connection(connection)
puts "Boundary contracts: Ruby #{RUBY_VERSION}, ActiveRecord #{ActiveRecord.version}, #{adapter}"
RSpec.describe('Standalone interoperability regressions') { include_examples 'interoperability boundaries' }
