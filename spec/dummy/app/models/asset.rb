# frozen_string_literal: true

class Asset < ApplicationRecord
  belongs_to :organisation
  has_and_belongs_to_many :service_industries
end
