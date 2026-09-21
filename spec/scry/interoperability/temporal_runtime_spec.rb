# frozen_string_literal: true

require_relative "support"

RSpec.describe "Temporal runtime contracts", :interoperability do
  around do |example|
    previous_zone = Time.zone
    previous_default = Time.zone_default
    Time.zone_default = nil
    Time.zone = nil
    Timecop.freeze(Time.utc(2026, 9, 7, 12)) { example.run }
  ensure
    Time.zone = previous_zone
    Time.zone_default = previous_default
  end

  %w[within_next within_previous not_within_next not_within_previous].each do |predicate|
    it "executes #{predicate} without an application time zone" do
      now = Time.current
      past = create(:user, created_at: now - 3600)
      future = create(:user, created_at: now + 3600)
      scope = User.where(id: [past.id, future.id])
      expected = %w[within_previous not_within_next].include?(predicate) ? past : future

      expect(apply(scope, property("created_at", predicate, "P1D")).ids).to eq([expected.id])
    end
  end
end
