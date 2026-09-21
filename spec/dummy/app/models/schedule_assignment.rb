# frozen_string_literal: true

class ScheduleAssignment < ApplicationRecord
  belongs_to :technician
  belongs_to :job
end
