# frozen_string_literal: true

module Scry
  module Predications
    module Global
      def null
        eq(nil)
      end

      def not_null
        not_eq(nil)
      end
    end
  end
end
