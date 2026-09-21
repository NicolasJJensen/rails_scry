# frozen_string_literal: true

FactoryBot.define do
  factory :email do
    sequence(:address) { |n| "user#{n}@example.com" }
    account { nil }
  end
end
