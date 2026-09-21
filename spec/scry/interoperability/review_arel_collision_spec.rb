# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe 'Arel extension collision visibility' do
  {private: 'parse_temporal_value', protected: 'parse_temporal_value', public: 'parse_temporal_value', private_predicate: 'within'}.each do |visibility, name|
    it "rejects #{visibility} conflicts without installing any modules" do
      visibility = :private if visibility == :private_predicate
      code = <<~RUBY
        require 'rails_scry'
        Arel::Predications.module_eval do
          define_method(#{name.inspect}) { :host_behavior }
          #{visibility} #{name.inspect}.to_sym
        end
        begin
          Scry.install_arel_extensions!
          abort('collision not detected')
        rescue Scry::FilterError
          [Scry::Predications::Global, Scry::Predications::Association, Scry::Predications::Temporal].each do |extension|
            abort('partial installation') if Arel::Predications.ancestors.include?(extension)
          end
        end
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', code)
      expect(status.success?).to be(true), output
    end
  end
end
