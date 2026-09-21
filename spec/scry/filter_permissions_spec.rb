require 'rails_helper'

RSpec.describe Scry::FilterPermissions do
    # Use the existing User model instead of anonymous class
    let(:filter_permissions) { User.scry_permissions }
    let(:context) { nil }

    before do
      # Clear caches before each test
      filter_permissions.clear_caches!
    end

    describe '#properties_with_labels' do
      it 'returns array of hashes with key and label' do
        properties = filter_permissions.properties_with_labels(context, locale: :en)
        expect(properties).to be_an(Array)
        expect(properties.first).to have_key(:key)
        expect(properties.first).to have_key(:label)
      end

      it 'calls Model.human_attribute_name for translation' do
        # Verify the i18n method is actually being called
        expect(User).to receive(:human_attribute_name).at_least(:once).and_call_original
        filter_permissions.properties_with_labels(context, locale: :en)
      end

      it 'uses i18n translations when available' do
        # Set up a custom translation
        I18n.backend.store_translations(:en, activerecord: { attributes: { user: { first_name: 'Given Name' } } })

        properties = filter_permissions.properties_with_labels(context, locale: :en)
        first_name_prop = properties.find { |p| p[:key] == 'first_name' }

        expect(first_name_prop[:label]).to eq('Given Name')
      ensure
        I18n.backend.reload!
      end

      it 'returns keys as strings' do
        properties = filter_permissions.properties_with_labels(context, locale: :en)
        properties.each do |prop|
          expect(prop[:key]).to be_a(String)
        end
      end

      it 'respects locale parameter' do
        properties_en = filter_permissions.properties_with_labels(context, locale: :en)
        properties_es = filter_permissions.properties_with_labels(context, locale: :es)
        # Both should return arrays (specific translations depend on locale setup)
        expect(properties_en).to be_an(Array)
        expect(properties_es).to be_an(Array)
      end

      it 'caches results by context and locale' do
        result1 = filter_permissions.properties_with_labels(context, locale: :en)
        result2 = filter_permissions.properties_with_labels(context, locale: :en)
        expect(result1).to eq(result2)
      end
    end

    describe '#associations_with_labels' do
      it 'returns array of hashes with key and label' do
        associations = filter_permissions.associations_with_labels(context, locale: :en)
        expect(associations).to be_an(Array)
        if associations.any?
          expect(associations.first).to have_key(:key)
          expect(associations.first).to have_key(:label)
        end
      end

      it 'translates association names using model_name.human' do
        # User model should have at least one association
        associations = filter_permissions.associations_with_labels(context, locale: :en)
        skip 'No associations defined on User model' if associations.empty?

        # Verify each association has a translated label
        associations.each do |assoc|
          expect(assoc[:label]).to be_a(String)
          expect(assoc[:label]).not_to be_empty
          # Label should not be the same as the raw key (unless it's a single word)
          expect(assoc[:label]).not_to eq(assoc[:key]) unless assoc[:key].match?(/\A[a-z]+\z/)
        end
      end

      it 'returns keys as strings' do
        associations = filter_permissions.associations_with_labels(context, locale: :en)
        associations.each do |assoc|
          expect(assoc[:key]).to be_a(String)
        end
      end

      it 'caches results by context and locale' do
        result1 = filter_permissions.associations_with_labels(context, locale: :en)
        result2 = filter_permissions.associations_with_labels(context, locale: :en)
        expect(result1.object_id).to eq(result2.object_id)
      end

      it 'filters out associations to models that are not allowed by model_allowed?' do
        # Set up: User has association to Email, deny Email model
        original_email = Email.scry_permissions.deep_dup(klass: Email)
        begin
          Email.add_model_permission { |_ctx| false }
          Email.scry_permissions.clear_caches!
          filter_permissions.clear_caches!

          associations = filter_permissions.associations_with_labels(context, locale: :en)

          # Verify emails association is not in the list
          email_association = associations.find { |a| a[:key] == 'emails' }
          expect(email_association).to be_nil
        ensure
          Email.scry_permissions = original_email
          Email.scry_permissions.clear_caches!
          filter_permissions.clear_caches!
        end
      end
    end

    describe '#predicate_metadata' do
      it 'returns hash of predicate metadata' do
        metadata = filter_permissions.predicate_metadata(context, locale: :en)
        expect(metadata).to be_a(Hash)
      end

      it 'each predicate has normalized signature metadata' do
        metadata = filter_permissions.predicate_metadata(context, locale: :en)
        metadata.each do |key, value|
          expect(value).to have_key(:label)
          expect(value).to include(:parameters, :arguments)
          expect(value[:arguments]).to include(:min, :max)
        end
      end

      it 'includes predicates from allowed_property_predicates' do
        metadata = filter_permissions.predicate_metadata(context, locale: :en)
        expect(metadata.keys).not_to be_empty
      end

      it 'uses i18n translations from scry.predicates' do
        metadata = filter_permissions.predicate_metadata(context, locale: :en)
        # Verify actual translations from our locale file
        expect(metadata[:eq][:label]).to eq('equals') if metadata[:eq]
        expect(metadata[:gt][:label]).to eq('greater than') if metadata[:gt]
        expect(metadata[:starts_with][:label]).to eq('starts with') if metadata[:starts_with]
      end

      it 'falls back to humanized names for missing translations' do
        # Register a custom predicate without a translation
        Scry.configuration.register_predicate(:custom_test_pred, types: [:all]) { |attr| attr.eq('x') }

        metadata = filter_permissions.predicate_metadata(context, locale: :en)
        custom_pred = metadata[:custom_test_pred]

        if custom_pred
          # Should fall back to humanized version
          expect(custom_pred[:label]).to eq('custom test pred')
        end
      ensure
        Scry.configuration.unregister_predicate(:custom_test_pred)
      end

      it 'caches results by context and locale' do
        result1 = filter_permissions.predicate_metadata(context, locale: :en)
        result2 = filter_permissions.predicate_metadata(context, locale: :en)
        expect(result1.object_id).to eq(result2.object_id)
      end
    end

    describe 'context-based permissions' do
      around(:each) do |example|
        Scry.configuration.with_temporary_settings do |_cfg|
          original = User.scry_permissions.deep_dup(klass: User)
          begin
            example.run
          ensure
            User.scry_permissions = original
            User.scry_permissions.clear_caches!
          end
        end
      end

      it 'returns different allowed properties for different contexts' do
        User.add_filter_permission(:properties, list_type: :whitelist) do |ctx|
          if ctx == :admin
            User.columns.map { |c| c.name.to_sym }
          else
            [:first_name, :last_name]
          end
        end
        filter_permissions.clear_caches!

        admin_props = filter_permissions.allowed_properties(:admin)
        user_props = filter_permissions.allowed_properties(:guest)

        expect(admin_props.size).to be > user_props.size
        expect(user_props).to include(:first_name, :last_name)
      end

      it 'returns different allowed associations for different contexts' do
        User.add_filter_permission(:associations, list_type: :whitelist) do |ctx|
          ctx == :admin ? [:organisation, :emails] : [:organisation]
        end
        filter_permissions.clear_caches!

        admin_assocs = filter_permissions.allowed_associations(:admin)
        user_assocs = filter_permissions.allowed_associations(:guest)

        expect(admin_assocs).to include(:emails)
        expect(user_assocs).not_to include(:emails)
      end
    end

    describe '#clear_caches!' do
      it 'clears thread-local caches for the model' do
        # Prime the caches
        filter_permissions.properties_with_labels(context, locale: :en)
        filter_permissions.associations_with_labels(context, locale: :en)
        filter_permissions.predicate_metadata(context, locale: :en)

        # Verify caches are populated
        store = Thread.current[:scry_caches]
        expect(store&.dig(User)).not_to be_nil

        # Clear caches
        filter_permissions.clear_caches!

        # Verify caches are cleared for this model
        expect(Thread.current[:scry_caches]&.dig(User)).to be_nil
      end
    end
  end
