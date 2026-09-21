# frozen_string_literal: true

FactoryBot.define do
  factory :account do
    sequence(:username) { |n| "user#{n}" }
    password { "password" }
  end
end
