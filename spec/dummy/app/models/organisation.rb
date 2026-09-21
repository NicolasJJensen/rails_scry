# frozen_string_literal: true

class Organisation < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :assets, dependent: :destroy
  has_many :service_industries, dependent: :destroy

  validates :name, presence: true
end
