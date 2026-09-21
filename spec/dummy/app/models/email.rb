# frozen_string_literal: true

class Email < ApplicationRecord
  belongs_to :account, optional: true
  has_and_belongs_to_many :users
end
