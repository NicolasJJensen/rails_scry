# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    organisation
    first_name { "Test" }
    last_name { "User" }
    date_of_birth { Date.new(1990, 1, 1) }

    transient do
      emails_count { 0 }
      phones_count { 0 }
    end

    after(:create) do |user, evaluator|
      create_list(:email, evaluator.emails_count, users: [user]) if evaluator.emails_count > 0
      create_list(:phone, evaluator.phones_count, users: [user]) if evaluator.phones_count > 0
    end
  end
end
