# frozen_string_literal: true

class ServiceIndustry < ApplicationRecord
  belongs_to :organisation
  has_and_belongs_to_many :users
  has_and_belongs_to_many :assets
end
