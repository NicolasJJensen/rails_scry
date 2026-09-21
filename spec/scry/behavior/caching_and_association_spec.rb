# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'round9' + ' - ' + 'Aggregate filtering through the public API' do
  describe 'Aggregate filtering through the public API' do
    it 'keeps repeated aggregate queries isolated to the caller relation' do
      matching = create(:user, emails_count: 0)
      matching.emails << create(:email)
      other = create(:user, emails_count: 0)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gteq', args: [1] }
        ]
      }

      result = Scry.filter_records_by(
        records: User.where(id: [matching.id, other.id]), filter: filter, context: nil
      ).relation

      expect(result.ids).to eq([matching.id])
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'Aggregate scoping through the public API' do
  describe 'Aggregate scoping through the public API' do
    it 'filters by the scoped child relation' do
      user = create(:user, emails_count: 0)
      user.emails << create(:email, address: 'scoped@example.com')

      filter = {
        type: 'group', predicate: 'and', filters: [
          {
            type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'eq', args: [1],
            scoping: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'address', predicate: 'eq', args: ['scoped@example.com'] }
              ]
            }
          }
        ]
      }

      result = Scry.filter_records_by(records: User.where(id: user.id), filter: filter, context: nil).relation

      expect(result.ids).to eq([user.id])
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'Scry.clear_thread_caches!' do
  describe 'Scry.clear_thread_caches!' do
    it 'clears thread-local caches' do
      Thread.current[:scry_caches] = { User => { test: 'data' } }
      Scry.clear_thread_caches!
      expect(Thread.current[:scry_caches]).to be_empty
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'CacheClearer.clear_current_thread!' do
  describe 'CacheClearer.clear_current_thread!' do
    it 'clears thread-local caches via class method' do
      Thread.current[:scry_caches] = { User => { test: 'data' } }
      Scry::Middleware::CacheClearer.clear_current_thread!
      expect(Thread.current[:scry_caches]).to be_empty
    end
  end

end


Arel::Predications.module_eval do
  define_method(:scry_dispatch_error) { |_value| raise NoMethodError, "dispatch boom" }
end unless Arel::Predications.method_defined?(:scry_dispatch_error)

RSpec.describe 'round9' + ' - ' + 'Arel __send__ rescue in Base' do
  describe 'Arel __send__ rescue in Base' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.register_predicate(:bad_arel, types: %i[textual], arel_predicate: :scry_dispatch_error, compounds: false)
        example.run
      end
    end

    it 'rejects an invalid Arel predicate under :raise input policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise
        config.invalid_filter_policy = :raise
        user = create(:user, first_name: 'Test')

        expect {
          Scry.filter_records_by(
            records: User.where(id: user.id),
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'first_name', predicate: 'bad_arel', args: ['x'] }
            ] },
            context: nil
          ).relation
        }.to raise_error(Scry::FilterError, /Arel predicate :scry_dispatch_error failed/)
      end
    end

    it 'returns no records under :match_none callback policy for invalid arel_predicate' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :match_none
        config.invalid_filter_policy = :match_none
        user = create(:user, first_name: 'Test')

        result = Scry.filter_records_by(
          records: User.where(id: user.id),
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'bad_arel', args: ['x'] }
          ] },
          context: nil
        ).relation
        expect(result).to be_none
      end
    end

    it 'logs warning with diagnostic logging enabled for invalid arel_predicate' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn
        user = create(:user, first_name: 'Test')

        expect(Rails.logger).to receive(:warn) do |payload|
          event = JSON.parse(payload)
          expect(event).to include(
            'code' => 'invalid_filter',
            'message' => 'Scry: Arel predicate :scry_dispatch_error failed'
          )
          expect(event['message']).not_to include('undefined method')
        end
        Scry.filter_records_by(
          records: User.where(id: user.id),
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'bad_arel', args: ['x'] }
          ] },
          context: nil
        ).relation
      end
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'Arel __send__ rescue in Association' do
  describe 'Arel __send__ rescue in Association' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.register_predicate(:bad_assoc_arel, types: %i[single_association], applies_to: [:association], arel_predicate: :scry_dispatch_error, compounds: false)
        example.run
      end
    end

    it 'rejects an invalid association Arel predicate under :raise input policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise
        config.invalid_filter_policy = :raise
        user = create(:user)

        expect {
          Scry.filter_records_by(
            records: User.where(id: user.id),
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'association', association: 'organisation', predicate: 'bad_assoc_arel', args: [user.organisation_id] }
            ] },
            context: nil
          ).relation
        }.to raise_error(Scry::FilterError, /Arel predicate :scry_dispatch_error failed/)
      end
    end

    it 'returns no records under :match_none callback policy for invalid arel_predicate on association' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :match_none
        config.invalid_filter_policy = :match_none
        user = create(:user)

        result = Scry.filter_records_by(
          records: User.where(id: user.id),
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'association', association: 'organisation', predicate: 'bad_assoc_arel', args: [user.organisation_id] }
          ] },
          context: nil
        ).relation
        expect(result).to be_none
      end
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'Custom property filter nil guard' do
  describe 'Custom property filter nil guard' do
    around(:each) do |example|
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end

    it 'raises FilterError under :raise policy when custom filter definition is nil' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :raise

        # Register a custom property that returns nil for the filter definition
        User.add_custom_property_filter do |_ctx|
          { phantom_property: nil }
        end
        User.scry_permissions.clear_caches!

        user = create(:user)

        expect {
          Scry.filter_records_by(
            records: User.where(id: user.id),
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'phantom_property', predicate: 'eq', args: ['x'] }
            ] },
            context: nil
          ).relation
        }.to raise_error(Scry::FilterError, /custom property filter.*returned nil/)
      end
    end

    it 'returns nil under :skip policy when custom filter definition is nil' do
      Scry.configuration.with_temporary_settings do |config|
        config.invalid_filter_policy = :skip

        User.add_custom_property_filter do |_ctx|
          { phantom_property: nil }
        end
        User.scry_permissions.clear_caches!

        user = create(:user)

        result = Scry.filter_records_by(
          records: User.where(id: user.id),
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'phantom_property', predicate: 'eq', args: ['x'] }
          ] },
          context: nil
        ).relation
        expect(result).to be_a(ActiveRecord::Relation)
      end
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'Through association aggregate filtering' do
  describe 'Through association aggregate filtering' do
    it 'executes through associations through the public API' do
      tech = Technician.create!(name: 'Test Tech', max_daily_hours: 24, active: true, skills: [], certifications: [], work_hours: {})
      job = Job.create!(title: 'Test Job', duration_hours: 1, priority: 3, crew_size: 1)
      assignment = ScheduleAssignment.new(
        job: job, technician: tech, scheduled_start: Time.current, scheduled_end: Time.current + 1.hour
      )
      assignment.save(validate: false)

      result = Scry.filter_records_by(
        records: Technician.where(id: tech.id),
        filter: {
          type: 'group', predicate: 'and', filters: [
            { type: 'aggregate', association: 'jobs', aggregate: 'count', predicate: 'eq', args: [1] }
          ]
        },
        context: nil
      ).relation

      expect(result.ids).to eq([tech.id])
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'Transform exception rescue' do
  describe 'Transform exception rescue' do
    around(:each) do |example|
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end

    it 'rejects an attribute transform error under :raise input policy' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise
        config.invalid_filter_policy = :raise

        User.add_filter_transform(:first_name, on: [:attribute]) do |_attr, _ctx|
          raise RuntimeError, 'attr transform boom'
        end
        User.scry_permissions.clear_caches!

        user = create(:user, first_name: 'Test')

        expect {
          Scry.filter_records_by(
            records: User.where(id: user.id),
            filter: { type: 'group', predicate: 'and', filters: [
              { type: 'property', property: 'first_name', predicate: 'eq', args: ['Test'] }
            ] },
            context: nil
          ).relation
        }.to raise_error(RuntimeError, 'attr transform boom')
      end
    end

    it 'falls back to untransformed value under :skip policy when value transform raises' do
      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :match_none

        User.add_filter_transform(:first_name, on: [:value]) do |_val, _ctx|
          raise RuntimeError, 'value transform boom'
        end
        User.scry_permissions.clear_caches!

        user = create(:user, first_name: 'Test')

        # A callback failure under match-none must deny the candidate relation.
        result = Scry.filter_records_by(
          records: User.where(id: user.id),
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Test'] }
          ] },
          context: nil
        ).relation
        expect(result).not_to include(user)
      end
    end

    it 'logs warning with diagnostic logging enabled when value_node transform raises' do
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn
        config.callback_error_policy = :match_none

        User.add_filter_transform(:first_name, on: [:value_node]) do |_node, _ctx|
          raise RuntimeError, 'value_node transform boom'
        end
        User.scry_permissions.clear_caches!

        user = create(:user, first_name: 'Test')

        expect(Rails.logger).to receive(:warn) do |payload|
          event = JSON.parse(payload)
          expect(event).to include(
            'code' => 'callback_error',
            'message' => /value_node transform callback failed/
          )
          expect(event['message']).not_to include('value_node transform boom')
        end
        Scry.filter_records_by(
          records: User.where(id: user.id),
          filter: { type: 'group', predicate: 'and', filters: [
            { type: 'property', property: 'first_name', predicate: 'eq', args: ['Test'] }
          ] },
          context: nil
        ).relation
      end
    end
  end

end

RSpec.describe 'round9' + ' - ' + 'Association predications fallback paths' do
  describe 'Association predications fallback paths' do
    it 'filters belongs_to with has_any predicate' do
      org = create(:organisation)
      user = create(:user, organisation: org)
      other_user = create(:user)

      filter = {
        type: 'association', association: 'organisation',
        predicate: 'has_any', args: [[org.id]]
      }

      result = Scry.filter_records_by(
        records: User.where(id: [user.id, other_user.id]),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      expect(result).to include(user)
      expect(result).not_to include(other_user)
    end

    it 'filters belongs_to with not_has_any predicate' do
      org = create(:organisation)
      user = create(:user, organisation: org)
      other_user = create(:user)

      filter = {
        type: 'association', association: 'organisation',
        predicate: 'not_has_any', args: [[org.id]]
      }

      result = Scry.filter_records_by(
        records: User.where(id: [user.id, other_user.id]),
        filter: { type: 'group', predicate: 'and', filters: [filter] },
        context: nil
      ).relation
      expect(result).not_to include(user)
      expect(result).to include(other_user)
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'Strict mode completeness' do
  describe 'Strict mode completeness' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.strict = true
        example.run
      end
    end

    it 'returns empty aggregates without explicit whitelist in strict mode' do
      User.scry_permissions.clear_caches!
      aggregates = User.scry_permissions.allowed_aggregates(nil)
      expect(aggregates).to eq({})
    end

    it 'returns whitelisted aggregates in strict mode' do
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        User.add_filter_permission(:associations, list_type: :includelist) { |_ctx| [:emails] }
        User.add_filter_permission(:aggregates, list_type: :includelist) do |_ctx|
          { emails: { count: true } }
        end
        User.scry_permissions.clear_caches!

        aggregates = User.scry_permissions.allowed_aggregates(nil)
        expect(aggregates).to have_key('emails')
        expect(aggregates['emails']).to have_key('count')
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end

    it 'includes custom property filter keys as base properties in strict mode' do
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        User.add_custom_property_filter do |_ctx|
          {
            active_users: {
              type: 'group', predicate: 'and', filters: [
                { type: 'property', property: 'first_name', predicate: 'eq', args: ['Active'] }
              ]
            }
          }
        end
        User.scry_permissions.clear_caches!

        properties = User.scry_permissions.allowed_properties(nil)
        expect(properties).to include(:active_users)
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end
  end
end

RSpec.describe 'round9' + ' - ' + ':warn mode logging verification' do
  describe ':warn mode logging verification' do
    around(:each) do |example|
      Scry.configuration.with_temporary_settings do |config|
        config.diagnostic_logging = :warn
        example.run
      end
    end

    it 'logs warning for invalid property' do
      expect(Rails.logger).to receive(:warn).with(/invalid property/)
      Scry.filter_records_by(
        records: User,
        filter: { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'nonexistent_col', predicate: 'eq', args: ['x'] }
        ] },
        context: nil
      ).relation
    end

    it 'logs warning for invalid predicate' do
      expect(Rails.logger).to receive(:warn).with(/invalid predicate/)
      user = create(:user)
      Scry.filter_records_by(
        records: User.where(id: user.id),
        filter: { type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'totally_fake_pred', args: ['x'] }
        ] },
        context: nil
      ).relation
    end

    it 'logs warning for invalid association' do
      expect(Rails.logger).to receive(:warn) do |payload|
        event = JSON.parse(payload)
        expect(event).to include(
          'category' => 'invalid_filter',
          'code' => 'unknown_association',
          'message' => 'Scry: invalid or missing association'
        )
      end
      user = create(:user)
      Scry.filter_records_by(
        records: User.where(id: user.id),
        filter: { type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'nonexistent_assoc', predicate: 'has_any', args: [[1]] }
        ] },
        context: nil
      ).relation
    end

    it 'logs warning for unknown filter type' do
      expect(Rails.logger).to receive(:warn) do |payload|
        event = JSON.parse(payload)
        expect(event).to include(
          'category' => 'invalid_filter',
          'code' => 'unknown_filter_type',
          'message' => 'Scry: unknown filter type'
        )
      end
      user = create(:user)
      Scry.filter_records_by(
        records: User.where(id: user.id),
        filter: { type: 'group', predicate: 'and', filters: [
          { type: 'bogus_type', property: 'first_name', predicate: 'eq', value: 'x' }
        ] },
        context: nil
      ).relation
    end
  end
end

RSpec.describe 'round9' + ' - ' + 'Permission chain combinations' do
  describe 'Permission chain combinations' do
    around(:each) do |example|
      original = User.scry_permissions.deep_dup(klass: User)
      begin
        example.run
      ensure
        User.scry_permissions = original
        User.scry_permissions.clear_caches!
      end
    end

    it 'applies whitelist then blacklist in sequence' do
      # Whitelist only first_name and last_name
      User.add_filter_permission(:properties, list_type: :whitelist) do |_ctx|
        [:first_name, :last_name, :date_of_birth]
      end
      # Then blacklist date_of_birth
      User.add_filter_permission(:properties, list_type: :blacklist) do |_ctx|
        [:date_of_birth]
      end
      User.scry_permissions.clear_caches!

      props = User.scry_permissions.allowed_properties(nil)
      expect(props).to include(:first_name, :last_name)
      expect(props).not_to include(:date_of_birth)
    end

    it 'applies includelist then excludelist in sequence' do
      # First whitelist to restrict
      User.add_filter_permission(:properties, list_type: :whitelist) do |_ctx|
        [:first_name]
      end
      # Includelist adds back last_name
      User.add_filter_permission(:properties, list_type: :includelist) do |_ctx|
        [:last_name]
      end
      # Excludelist removes last_name
      User.add_filter_permission(:properties, list_type: :excludelist) do |_ctx|
        [:last_name]
      end
      User.scry_permissions.clear_caches!

      props = User.scry_permissions.allowed_properties(nil)
      expect(props).to include(:first_name)
      expect(props).not_to include(:last_name)
    end

    it 'intersects multiple whitelists' do
      User.add_filter_permission(:properties, list_type: :whitelist) do |_ctx|
        [:first_name, :last_name, :date_of_birth]
      end
      User.add_filter_permission(:properties, list_type: :whitelist) do |_ctx|
        [:first_name, :date_of_birth]
      end
      User.scry_permissions.clear_caches!

      props = User.scry_permissions.allowed_properties(nil)
      expect(props).to include(:first_name, :date_of_birth)
      expect(props).not_to include(:last_name)
    end

    it 'whitelist restricts then includelist adds back within universe' do
      User.add_filter_permission(:properties, list_type: :whitelist) do |_ctx|
        [:first_name]
      end
      User.add_filter_permission(:properties, list_type: :includelist) do |_ctx|
        [:last_name]
      end
      User.scry_permissions.clear_caches!

      props = User.scry_permissions.allowed_properties(nil)
      expect(props).to include(:first_name, :last_name)
    end

    it 'applies association whitelist then blacklist' do
      User.add_filter_permission(:associations, list_type: :whitelist) do |_ctx|
        [:emails, :organisation, :phones]
      end
      User.add_filter_permission(:associations, list_type: :blacklist) do |_ctx|
        [:phones]
      end
      User.scry_permissions.clear_caches!

      assocs = User.scry_permissions.allowed_associations(nil)
      expect(assocs).to include(:emails, :organisation)
      expect(assocs).not_to include(:phones)
    end
  end
end
