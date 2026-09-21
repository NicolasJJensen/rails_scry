# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'rbconfig'

RSpec.describe 'predicate registration receiver contracts' do
  def run_ruby(code)
    Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', code)
  end

  it 'requires an installed extension for predicates absent from the native Arel receiver' do
    code = <<~RUBY
      require 'rails_scry'
      config = Scry.configuration
      begin
        config.register_predicate(:registration_null, types: [:textual], compounds: false, arel_predicate: :null)
      rescue ArgumentError => error
        abort(error.message) unless error.message.include?('unknown Arel predicate')
        exit 0
      end
      abort('registration unexpectedly succeeded')
    RUBY

    _output, status = run_ruby(code)
    expect(status.success?).to be(true)
  end

  it 'accepts an extension predicate after explicit opt in' do
    code = <<~RUBY
      require 'rails_scry'
      config = Scry.configuration
      Scry.install_arel_extensions!
      config.register_predicate(:registration_null, types: [:textual], compounds: false, arel_predicate: :null)
    RUBY

    output, status = run_ruby(code)
    expect(status.success?).to be(true), output
  end

  it 'rejects private and protected methods on the actual receiver' do
    code = <<~RUBY
      require 'rails_scry'
      Arel::Predications.module_eval do
        def registration_private; end
        private :registration_private
        def registration_protected; end
        protected :registration_protected
      end
      config = Scry.configuration
      [:registration_private, :registration_protected].each do |name|
        begin
          config.register_predicate(name, types: [:textual], compounds: false, arel_predicate: name)
        rescue ArgumentError
          next
        end
        abort("\#{name} was accepted")
      end
    RUBY

    output, status = run_ruby(code)
    expect(status.success?).to be(true), output
  end

  it 'does not mutate global Arel while loading or initializing configuration' do
    code = <<~RUBY
      require 'rails_scry'
      before = Arel::Predications.ancestors
      Scry.configuration
      after = Arel::Predications.ancestors
      extensions = [Scry::Predications::Global, Scry::Predications::Association, Scry::Predications::Temporal]
      abort('global Arel was mutated') if extensions.any? { |extension| !before.include?(extension) && after.include?(extension) }
    RUBY

    output, status = run_ruby(code)
    expect(status.success?).to be(true), output
  end

  it 'rejects equality Arel predicates for association registrations' do
    config = Scry.configuration

    %i[eq not_eq eq_any eq_all not_eq_any not_eq_all].each do |arel_predicate|
      expect {
        config.register_predicate(
          :association_equality_registration,
          types: [:many_association],
          applies_to: [:association],
          compounds: false,
          arel_predicate:
        )
      }.to raise_error(ArgumentError, /association predicates cannot use/)
    end
  end
end
