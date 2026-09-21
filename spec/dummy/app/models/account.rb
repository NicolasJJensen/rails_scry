# frozen_string_literal: true

class Account < ApplicationRecord
  has_one :primary_user, class_name: 'User'
  has_many :users, dependent: :destroy
  has_many :emails, dependent: :destroy
  has_many :phones, dependent: :destroy
end
