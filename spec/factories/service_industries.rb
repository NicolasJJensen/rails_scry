# frozen_string_literal: true

FactoryBot.define do
  factory :service_industry do
    organisation
    name { "Test Industry" }
  end
end
