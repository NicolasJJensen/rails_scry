require_relative 'support'

RSpec.describe 'Filter input contracts', interoperability: true do
  %i[skip match_none raise].each do |mode|
    it "AF-14 handles a missing aggregate association in #{mode} mode" do
      Scry.configuration.invalid_filter_policy = mode
      filter = {type: 'aggregate', aggregate: 'count', predicate: 'gt', args: [0]}
      if mode == :raise
        expect { apply(User, filter) }.to raise_error(Scry::FilterError)
      else
        expect { apply(User, filter).to_sql }.not_to raise_error
      end
    end

    it "AF-14 handles malformed nested scoping in #{mode} mode" do
      Scry.configuration.invalid_filter_policy = mode
      filter = association('emails', 'has_any', nil, scoping: 'invalid')
      if mode == :raise
        expect { apply(User, filter) }.to raise_error(Scry::FilterError)
      else
        expect { apply(User, filter).to_sql }.not_to raise_error
      end
    end
  end
end
