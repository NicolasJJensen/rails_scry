require 'rails_helper'

RSpec.describe 'Permission resolution and discovery' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original = User.scry_permissions.deep_dup(klass: User)
      original_organisation = Organisation.scry_permissions.deep_dup(klass: Organisation)
      begin
        example.run
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_organisation
        Organisation.scry_permissions.clear_caches!
      end
    end
  end


  describe 'predicates_by_property includelist branch' do
    it 'includelist with :all restores all predicates for that column type' do
      User.add_filter_permission(:property_predicates, list_type: :includelist) do |_ctx|
        { first_name: :all }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_property, nil)
      # :all restores all predicates for the column's type (textual)
      textual_preds = Scry.configuration.predicate_registry.by_type(:string)
      textual_preds.each do |pred|
        expect(preds[:first_name]).to include(pred)
      end
    end

    it 'includelist with nil preserves existing predicates' do
      User.add_filter_permission(:property_predicates, list_type: :includelist) do |_ctx|
        { first_name: nil }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_property, nil)
      # nil means no change; predicates should remain as-is
      expect(preds[:first_name]).to include(:eq)
      expect(preds[:first_name]).to include(:matches)
    end

    it 'includelist with array unions with base predicates' do
      # First blacklist :matches, then includelist it back
      User.add_filter_permission(:property_predicates, list_type: :blacklist) do |_ctx|
        { first_name: [:matches] }
      end
      User.add_filter_permission(:property_predicates, list_type: :includelist) do |_ctx|
        { first_name: [:matches] }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_property, nil)
      # :matches was blacklisted then included back (since it's in base predicates)
      expect(preds[:first_name]).to include(:matches)
    end
  end


  describe 'predicates_by_property whitelist with :all value' do
    it 'preserves all existing predicates when :all is specified' do
      # Get baseline predicates
      baseline = User.scry_permissions.send(:predicates_by_property, nil)[:first_name].dup

      User.add_filter_permission(:property_predicates, list_type: :whitelist) do |_ctx|
        { first_name: :all }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_property, nil)
      expect(preds[:first_name]).to match_array(baseline)
    end
  end


  describe 'predicates_by_property blacklist with nil for a property' do
    it 'preserves predicates for properties not mentioned in blacklist hash' do
      baseline_first_name = User.scry_permissions.send(:predicates_by_property, nil)[:first_name].dup

      # Blacklist :eq on last_name only; first_name is not mentioned (nil predicates)
      User.add_filter_permission(:property_predicates, list_type: :blacklist) do |_ctx|
        { last_name: [:eq] }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_property, nil)
      # first_name should be unaffected (nil guard preserves them)
      expect(preds[:first_name]).to match_array(baseline_first_name)
      # last_name should have :eq removed
      expect(preds[:last_name]).not_to include(:eq)
    end
  end


  describe 'predicates_by_type includelist with :all value' do
    it 'restores all predicates for the specified type' do
      # First blacklist some predicates globally
      User.add_filter_permission(:predicates, list_type: :blacklist) do |_ctx|
        [:eq, :matches]
      end
      # Then includelist :all for textual types
      User.add_filter_permission(:type_predicates, list_type: :includelist) do |_ctx|
        { string: :all }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_type, nil)
      all_string_preds = Scry.configuration.predicate_registry.by_type(:string)
      # :all restores all predicates registered for :string type
      expect(preds[:string]).to match_array(all_string_preds)
    end
  end


  describe 'predicates_by_type whitelist and blacklist' do
    it 'whitelist restricts type predicates to intersection' do
      User.add_filter_permission(:type_predicates, list_type: :whitelist) do |_ctx|
        { string: [:eq, :matches] }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_type, nil)
      expect(preds[:string]).to include(:eq)
      expect(preds[:string]).to include(:matches)
      expect(preds[:string]).not_to include(:starts_with)
    end

    it 'blacklist removes specified type predicates' do
      User.add_filter_permission(:type_predicates, list_type: :blacklist) do |_ctx|
        { string: [:eq] }
      end
      User.scry_permissions.clear_caches!

      preds = User.scry_permissions.send(:predicates_by_type, nil)
      expect(preds[:string]).not_to include(:eq)
      expect(preds[:string]).to include(:matches)
    end
  end


  describe 'property_predicates permission block exception' do
    it 'raises FilterError when property_predicates block raises' do
      User.add_filter_permission(:property_predicates, list_type: :whitelist) do |_ctx|
        raise RuntimeError, 'broken block'
      end
      User.scry_permissions.clear_caches!

      expect {
        User.scry_permissions.send(:predicates_by_property, nil)
      }.to raise_error(Scry::FilterError, "Scry: permission block raised RuntimeError")
    end
  end


  describe 'type_predicates permission block exception' do
    it 'raises FilterError when type_predicates block raises' do
      User.add_filter_permission(:type_predicates, list_type: :whitelist) do |_ctx|
        raise RuntimeError, 'type block error'
      end
      User.scry_permissions.clear_caches!

      expect {
        User.scry_permissions.send(:predicates_by_type, nil)
      }.to raise_error(Scry::FilterError, "Scry: permission block raised RuntimeError")
    end
  end


  describe 'allowed_aggregates whitelist narrowing' do
    it 'narrows from true to specific attributes via whitelist' do
      # Default aggregates include count: true for allowed associations
      # Whitelist with specific columns narrows count to a Set
      User.add_filter_permission(:aggregates, list_type: :whitelist) do |_ctx|
        { emails: { count: ['id'] } }
      end
      User.scry_permissions.clear_caches!

      aggs = User.scry_permissions.allowed_aggregates(nil)
      expect(aggs['emails']['count']).to be_a(Set)
      expect(aggs['emails']['count']).to include('id')
    end
  end


  describe 'allowed_aggregates blacklist with current == true' do
    it 'deletes the aggregate key when blacklisting specific attrs from true' do
      # Default has count: true. Blacklist count with specific attrs
      # When current == true and val is not :all, the key is deleted entirely
      User.add_filter_permission(:aggregates, list_type: :blacklist) do |_ctx|
        { emails: { count: ['some_col'] } }
      end
      User.scry_permissions.clear_caches!

      aggs = User.scry_permissions.allowed_aggregates(nil)
      # count key should be deleted because can't subtract specific attrs from "all"
      expect(aggs.dig('emails', 'count')).to be_nil
    end
  end


  describe 'allowed_aggregates blacklist with Set subtraction' do
    it 'subtracts specific attributes from a Set, keeping remaining' do
      # Set up aggregates with a Set value
      User.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
        { emails: { min: ['id', 'created_at'] } }
      end
      User.scry_permissions.clear_caches!

      # Verify base state
      aggs = User.scry_permissions.allowed_aggregates(nil)
      expect(aggs['emails']['min']).to include('id')
      expect(aggs['emails']['min']).to include('created_at')

      # Now blacklist one attr
      User.add_filter_permission(:aggregates, list_type: :blacklist) do |_ctx|
        { emails: { min: ['id'] } }
      end
      User.scry_permissions.clear_caches!

      aggs = User.scry_permissions.allowed_aggregates(nil)
      expect(aggs['emails']['min']).not_to include('id')
      expect(aggs['emails']['min']).to include('created_at')
    end

    it 'deletes aggregate key when all attributes are subtracted' do
      # Blacklist all min attributes to get the key deleted entirely
      User.add_filter_permission(:aggregates, list_type: :blacklist) do |_ctx|
        { emails: { min: :all } }
      end
      User.scry_permissions.clear_caches!

      aggs = User.scry_permissions.allowed_aggregates(nil)
      expect(aggs.dig('emails', 'min')).to be_nil
    end
  end


  describe 'allowed_aggregates whitelist Set intersection' do
    it 'keeps only the intersection of current Set and whitelisted Set' do
      User.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
        { emails: { min: ['id', 'created_at'] } }
      end
      User.add_filter_permission(:aggregates, list_type: :whitelist) do |_ctx|
        { emails: { min: ['created_at', 'nonexistent'] } }
      end
      User.scry_permissions.clear_caches!

      aggs = User.scry_permissions.allowed_aggregates(nil)
      expect(aggs['emails']['min']).to include('created_at')
      expect(aggs['emails']['min']).not_to include('id')
      expect(aggs['emails']['min']).not_to include('nonexistent')
    end
  end


  describe 'FilterPermissions#[] with invalid type' do
    it 'raises ArgumentError for invalid type' do
      expect {
        User.scry_permissions[:totally_invalid_type]
      }.to raise_error(ArgumentError, /type must be one of/)
    end
  end


  describe 'Base abstract methods' do
    it 'raises NotImplementedError when calling #property on Base' do
      user = create(:user)
      base = Scry::Filters::Base.new(
        model: User, filter: { predicate: 'eq', value: 1 }, context: nil
      )
      expect { base.property }.to raise_error(NotImplementedError, /must implement.*#property/)
    end

    it 'raises NotImplementedError when calling #apply on Base' do
      base = Scry::Filters::Base.new(
        model: User, filter: { predicate: 'eq', value: 1 }, context: nil
      )
      expect { base.apply }.to raise_error(NotImplementedError, /must implement.*#apply/)
    end
  end


  describe 'filter_capabilities rescue' do
    it 'returns fallback hash when discovery raises' do
      broken_perms = double('perms')
      allow(broken_perms).to receive(:to_h).and_raise(RuntimeError, 'boom')

      stub_model = Class.new do
        def self.name; 'BrokenModel'; end
        def self.scry_permissions; end
      end
      allow(stub_model).to receive(:respond_to?).with(:scry_permissions).and_return(true)
      allow(stub_model).to receive(:scry_permissions).and_return(broken_perms)

      result = Scry.filter_capabilities(model: stub_model)
      expect(result).to eq(Scry.empty_information.merge(error: true))
      expect(result).to be_frozen
      expect(result.values).to all(be_frozen)
    end

    it 'returns fallback metadata when invalid_filter_policy is :raise' do
      Scry.configuration.invalid_filter_policy = :raise

      broken_perms = double('perms')
      allow(broken_perms).to receive(:to_h).and_raise(RuntimeError, 'boom')

      stub_model = Class.new do
        def self.name; 'BrokenModel'; end
        def self.scry_permissions; end
      end
      allow(stub_model).to receive(:respond_to?).with(:scry_permissions).and_return(true)
      allow(stub_model).to receive(:scry_permissions).and_return(broken_perms)

      expect(Scry.filter_capabilities(model: stub_model))
        .to eq(Scry.empty_information.merge(error: true))
    end

    it 'uses the canonical discovery fallback through the model API' do
      context = Object.new
      Organisation.add_filter_permission(:properties) { |_ctx| raise 'discovery callback failed' }

      expect { Organisation.filter_capabilities(context) }
        .to raise_error(RuntimeError, 'discovery callback failed')
      expect { Organisation.filter_capabilities(context) }
        .to raise_error(RuntimeError, 'discovery callback failed')

      Scry.configuration.callback_error_policy = :match_none
      expect(Organisation.filter_capabilities(context))
        .to eq(Scry.empty_information.merge(error: true))
      expect(Organisation.filter_capabilities(context))
        .to eq(Scry.empty_information.merge(error: true))
    end
  end
end
