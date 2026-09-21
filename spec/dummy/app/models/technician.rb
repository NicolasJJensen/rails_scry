# frozen_string_literal: true

class Technician < ApplicationRecord
  has_many :schedule_assignments, dependent: :destroy
  has_many :jobs, through: :schedule_assignments
end
