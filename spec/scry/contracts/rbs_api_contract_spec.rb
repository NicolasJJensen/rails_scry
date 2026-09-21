# frozen_string_literal: true

require "rails_helper"
require "rbs"

RSpec.describe "public RBS API contracts" do
  it "documents Diagnostic#to_h as a metadata hash" do
    path = File.expand_path("../../../sig/rails_scry.rbs", __dir__)
    buffer = RBS::Buffer.new(name: path, content: File.read(path))
    declarations = RBS::Parser.parse_signature(buffer).last
    scry = declarations.find { |declaration| declaration.name.name == :Scry }
    diagnostic = scry.members.find do |member|
      member.respond_to?(:name) && member.name.name == :Diagnostic
    end
    to_h = diagnostic.members.find { |member| member.respond_to?(:name) && member.name == :to_h }

    expect(to_h).to be_present
    method_type = to_h.overloads.first.method_type
    expect(method_type.to_s).to eq("() -> metadata")
  end
end
