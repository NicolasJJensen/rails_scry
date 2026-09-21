# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  include Scry::Filterable
  primary_abstract_class
end
