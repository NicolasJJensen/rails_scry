require 'rails_helper'

RSpec.describe 'Scry permissions caching' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      example.run
    end
  end

  describe 'automatic invalidation on predicate changes' do
    it 'reflects newly registered and unregistered predicates without manual cache clearing' do
      before = User.filter_capabilities(nil)[:property_predicates][:first_name]
      expect(before).not_to include(:runtime_pred)

      Scry.configure do |c|
        c.register_predicate(:runtime_pred, types: [:textual]) { |attr, v| attr.matches("%#{v}%") }
      end

      after_reg = User.filter_capabilities(nil)[:property_predicates][:first_name]
      expect(after_reg).to include(:runtime_pred)

      Scry.configure do |c|
        c.unregister_predicate(:runtime_pred, :runtime_pred_any, :runtime_pred_all)
      end

      after_unreg = User.filter_capabilities(nil)[:property_predicates][:first_name]
      expect(after_unreg).not_to include(:runtime_pred)
    end
  end

  describe 'type-scoped predicate invalidation' do
    it 'removes a predicate from one type while retaining it for another' do
      Scry.configure do |c|
        c.register_predicate(:scoped_pred, types: [:textual, :numerical]) { |attr, v| attr.eq(v) }
      end

      u1 = create(:user, first_name: 'Target')
      _u2 = create(:user, first_name: 'Other')
      a1 = create(:asset, cost: 7)
      _a2 = create(:asset, cost: 9)

      # Works for textual
      f_txt = { type: 'group', predicate: 'and', filters: [ { type: 'property', property: 'first_name', predicate: 'scoped_pred', args: ['Target'] } ] }
      expect(Scry.filter_records_by(records: User, filter: f_txt, context: nil).relation).to match_array([u1])

      # Works for numerical
      f_num = { type: 'group', predicate: 'and', filters: [ { type: 'property', property: 'cost', predicate: 'scoped_pred', args: [7] } ] }
      expect(Scry.filter_records_by(records: Asset, filter: f_num, context: nil).relation).to match_array([a1])

      Scry.configure do |c|
        c.unregister_predicate_from_type(:textual, :scoped_pred)
      end

      # Now textual should reject predicate (returns original records), numerical still works
      result_txt = Scry.filter_records_by(records: User, filter: f_txt, context: nil).relation
      expect(result_txt).to be_a(ActiveRecord::Relation)
      expect(result_txt).not_to match_array([u1])
      expect(Scry.filter_records_by(records: Asset, filter: f_num, context: nil).relation).to match_array([a1])
    end
  end

  describe 'type group modifications' do
    it 'updates allowed predicates for properties when a type is removed from a group' do
      # Add a temporal-only predicate and verify it appears for date_of_birth
      Scry.configure do |c|
        c.register_predicate(:temp_only, types: [:temporal]) { |attr, v| attr.gteq(v) }
      end

      preds_before = User.filter_capabilities(nil)[:property_predicates]
      expect(preds_before[:date_of_birth]).to include(:temp_only)

      # Remove :date from :temporal group and ensure temp_only drops from date_of_birth
      Scry.configure do |c|
        c.unregister_types_from_group(:temporal, :date)
      end

      preds_after = User.filter_capabilities(nil)[:property_predicates]
      expect(preds_after[:date_of_birth]).not_to include(:temp_only)
    end
  end

  describe 'nested temporary settings' do
    it 'restores inner and outer configuration layers correctly' do
      # Outer layer adds :outer_pred
      Scry.configuration.with_temporary_settings do |outer|
        outer.register_predicate(:outer_pred, types: [:textual]) { |attr, v| attr.eq(v) }
        expect(User.filter_capabilities(nil)[:property_predicates][:first_name]).to include(:outer_pred)

        # Inner layer adds :inner_pred
        Scry.configuration.with_temporary_settings do |inner|
          inner.register_predicate(:inner_pred, types: [:textual]) { |attr, v| attr.eq(v) }
          pp = User.filter_capabilities(nil)[:property_predicates][:first_name]
          expect(pp).to include(:outer_pred)
          expect(pp).to include(:inner_pred)
        end

        # After inner block: inner predicate gone, outer persists
        mid = User.filter_capabilities(nil)[:property_predicates][:first_name]
        expect(mid).to include(:outer_pred)
        expect(mid).not_to include(:inner_pred)
      end

      # After outer block: both removed
      final = User.filter_capabilities(nil)[:property_predicates][:first_name]
      expect(final).not_to include(:outer_pred)
      expect(final).not_to include(:inner_pred)
    end
  end
end
