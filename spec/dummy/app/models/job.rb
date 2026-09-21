# frozen_string_literal: true

class Job < ApplicationRecord
  has_many :schedule_assignments, dependent: :destroy
  has_many :technicians, through: :schedule_assignments
end
