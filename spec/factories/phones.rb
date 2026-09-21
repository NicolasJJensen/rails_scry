# frozen_string_literal: true

FactoryBot.define do
  factory :phone do
    sequence(:e164) { |n| "+1555000#{n.to_s.rjust(4, '0')}" }
    account { nil }
  end
end
