# frozen_string_literal: true

module Scry
  class AggregateRegistry < BaseRegistry
    # Keep extension metadata discoverable alongside the translated label. The
    # executable builder is intentionally retained in the registry entry, but
    # omitted here because metadata is commonly serialized for clients.
    def build_metadata(name, aggregate, locale)
      {
        label: translate(name, locale),
        types: aggregate[:types],
        result_type: aggregate[:result_type],
        distinct: aggregate[:distinct],
        empty_value: aggregate[:empty_value],
        property: aggregate[:property],
        adapters: aggregate[:adapters]
      }
    end

    private

    def i18n_prefix
      "aggregates"
    end
  end
end
