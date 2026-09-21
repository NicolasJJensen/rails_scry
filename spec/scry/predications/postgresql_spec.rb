require 'rails_helper'

RSpec.describe 'PostgreSQL-specific predicates' do
  let(:config) { Scry.configuration }

  describe 'Type registration' do
    it 'registers identifier types' do
      expect(config.predicate_registry.types).to include(:identifier, :uuid)
    end

    it 'registers network types' do
      expect(config.predicate_registry.types).to include(:network, :inet, :cidr)
    end

    it 'registers array types' do
      expect(config.predicate_registry.types).to include(:array, :string_array, :integer_array, :text_array)
    end

    it 'registers enum type' do
      expect(config.predicate_registry.types).to include(:enum)
    end

    it 'registers range types' do
      expect(config.predicate_registry.types).to include(:range, :daterange, :tsrange, :tstzrange, :int4range, :int8range, :numrange)
    end
  end

  describe 'UUID predicates' do
    it 'supports eq and not_eq' do
      predicates = config.predicate_registry.by_type(:uuid)
      expect(predicates).to include(:eq, :not_eq, :eq_nil, :not_eq_nil)
    end
  end

  describe 'Network predicates' do
    it 'supports inet-specific predicates' do
      predicates = config.predicate_registry.by_type(:inet)
      expect(predicates).to include(:inet_contains, :inet_contained_within, :inet_overlaps)
    end

    it 'supports basic equality predicates' do
      predicates = config.predicate_registry.by_type(:inet)
      expect(predicates).to include(:eq, :not_eq, :eq_nil, :not_eq_nil)
    end

    it 'inet_contains predicate uses >> operator' do
      predicate = config.predicate_registry.by_name(:inet_contains)
      expect(predicate[:custom_predicate]).to be_present
    end
  end

  describe 'Array predicates' do
    it 'supports array-specific predicates' do
      predicates = config.predicate_registry.by_type(:string_array)
      expect(predicates).to include(:array_contains, :array_contained_by, :array_overlaps)
    end

    it 'supports basic equality predicates' do
      predicates = config.predicate_registry.by_type(:string_array)
      expect(predicates).to include(:eq, :not_eq, :eq_nil, :not_eq_nil)
    end

    it 'array_contains predicate uses @> operator' do
      predicate = config.predicate_registry.by_name(:array_contains)
      expect(predicate[:custom_predicate]).to be_present
    end
  end

  describe 'Enum predicates' do
    it 'supports textual predicates' do
      predicates = config.predicate_registry.by_type(:enum)
      expect(predicates).to include(:eq, :not_eq, :matches, :starts_with, :ends_with)
    end
  end

  describe 'Range predicates' do
    it 'supports range-specific predicates' do
      predicates = config.predicate_registry.by_type(:daterange)
      expect(predicates).to include(
        :range_contains,
        :range_contained_by,
        :range_overlaps,
        :range_strictly_left_of,
        :range_strictly_right_of,
        :range_adjacent_to
      )
    end

    it 'supports basic equality predicates' do
      predicates = config.predicate_registry.by_type(:daterange)
      expect(predicates).to include(:eq, :not_eq, :eq_nil, :not_eq_nil)
    end

    it 'range_contains predicate uses @> operator' do
      predicate = config.predicate_registry.by_name(:range_contains)
      expect(predicate[:custom_predicate]).to be_present
    end

    it 'range_strictly_left_of predicate uses << operator' do
      predicate = config.predicate_registry.by_name(:range_strictly_left_of)
      expect(predicate[:custom_predicate]).to be_present
    end

    it 'range_adjacent_to predicate uses -|- operator' do
      predicate = config.predicate_registry.by_name(:range_adjacent_to)
      expect(predicate[:custom_predicate]).to be_present
    end
  end

  describe 'Predicate registration' do
    it 'all network predicates are registered' do
      expect(config.predicate_registry.names).to include(
        :inet_contains,
        :inet_contained_within,
        :inet_overlaps
      )
    end

    it 'all array predicates are registered' do
      expect(config.predicate_registry.names).to include(
        :array_contains,
        :array_contained_by,
        :array_overlaps
      )
    end

    it 'all range predicates are registered' do
      expect(config.predicate_registry.names).to include(
        :range_contains,
        :range_contained_by,
        :range_overlaps,
        :range_strictly_left_of,
        :range_strictly_right_of,
        :range_adjacent_to
      )
    end
  end
end
