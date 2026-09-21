# frozen_string_literal: true

module Scry
  module Predications
    # TODO: Consider extracting temporal predications into a separate addon gem.
    # These monkey-patch Arel::Predications and may conflict with other gems or future Arel versions.
    #
    # NULL handling: All temporal predicates use comparison operators (gt, lt, eq)
    # which exclude NULL values by SQL semantics. Rows where the temporal column
    # is NULL will never match any temporal predicate, including negated ones
    # (not_within, not_within_previous, not_within_next). To include NULLs,
    # combine with an eq_nil predicate in an OR group.
    module Temporal
      def within(value)
        value = parse_temporal_value(value)
        gt(value.ago).and(lt(value.since))
      end

      def within_previous(value)
        value = parse_temporal_value(value)
        gt(value.ago)
      end

      def within_next(value)
        value = parse_temporal_value(value)
        lt(value.since)
      end

      def not_within(value)
        value = parse_temporal_value(value)
        lt(value.ago).or(gt(value.since))
      end

      def not_within_previous(value)
        value = parse_temporal_value(value)
        lt(value.ago)
      end

      def not_within_next(value)
        value = parse_temporal_value(value)
        gt(value.since)
      end

      private

      def parse_temporal_value(value)
        case value
        when ActiveSupport::Duration
          value
        when String
          ActiveSupport::Duration.parse(value)
        else
          raise ArgumentError, "Expected ActiveSupport::Duration or String, got #{value.class}"
        end
      end
    end
  end
end
