# frozen_string_literal: true

FactoryBot.define do
  factory :asset do
    organisation
    name { "Test Asset" }
    description { "A test asset" }
    status { 0 }
    cost { 100.00 }
  end
end
