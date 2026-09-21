# frozen_string_literal: true

class User < ApplicationRecord
  belongs_to :organisation
  belongs_to :account, optional: true

  has_and_belongs_to_many :emails
  has_and_belongs_to_many :phones
  has_and_belongs_to_many :service_industries
end
