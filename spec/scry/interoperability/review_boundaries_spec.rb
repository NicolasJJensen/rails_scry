# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/interoperability_boundaries'

RSpec.describe 'Reviewed interoperability regressions' do
  include_examples 'interoperability boundaries'
end
