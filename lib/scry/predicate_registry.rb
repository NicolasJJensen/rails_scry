# frozen_string_literal: true

module Scry
  class PredicateRegistry < BaseRegistry
    def apply_types_to_predicate(name, *types)
      predicate = by_name(name)
      return unless predicate

      register(predicate.merge(types: (predicate[:types] | types.map(&:to_sym))))
    end

    private

    def build_metadata(name, predicate, locale)
      {
        label: translate(name, locale),
        types: Array(predicate[:types]).map(&:to_s),
        parameters: predicate[:parameters],
        arguments: {min: predicate.dig(:arguments, :min), max: predicate.dig(:arguments, :max)},
        applies_to: predicate[:applies_to]
      }
    end

    def i18n_prefix
      "predicates"
    end

    def translate(name, locale)
      I18n.t("scry.predicates.#{name}",
             locale: locale,
             default: name.to_s.humanize.downcase)
    end
  end
end
