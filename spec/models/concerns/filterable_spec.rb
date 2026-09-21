require 'rails_helper'
require 'ostruct'

RSpec.describe 'filterable class' do
  let(:subject) do
    Class.new do
      def self.columns; end
      def self.encrypted_attributes; end
      def self.reflect_on_all_associations; end
      def self.reflect_on_association(name)
        reflect_on_all_associations.find { |a| a.name == name }
      end
      def self.human_attribute_name(attr, options = {})
        attr.to_s.humanize
      end
    end
  end
  let(:columns) do
    [
      OpenStruct.new({name: 'id', type: 'integer'}),
      OpenStruct.new({name: 'email', type: 'string'}),
      OpenStruct.new({name: 'password', type: 'string'}),
      OpenStruct.new({name: 'first_name', type: 'string'}),
      OpenStruct.new({name: 'last_name', type: 'string'}),
      OpenStruct.new({name: 'date_of_birth', type: 'timestamp'}),
      OpenStruct.new({name: 'address', type: 'string'}),
      OpenStruct.new({name: 'created_at', type: 'timestamp'}),
      OpenStruct.new({name: 'updated_at', type: 'timestamp'})
    ]
  end
  let(:reflected_associations) do
    # Create mock classes for associations
    tags_klass = Struct.new(:model_name) do
      # Match the model-level discovery contract used by FilterPermissions.
      # The fixture is intentionally not an ActiveRecord model, but its
      # associated target must still advertise that it can be inspected.
      def self.scry_permissions
        :fixture_permissions
      end

      def self.model_allowed?(_context)
        true
      end

      def self.model_name
        Struct.new(:human) do
          def human(count: 1)
            count == 1 ? 'Tag' : 'Tags'
          end
        end.new
      end
    end

    [
      OpenStruct.new({
        name: :tags,
        macro: 'has_and_belongs_to_many',
        collection?: true,
        klass: tags_klass
      }),
      OpenStruct.new({
        name: :roles,
        macro: 'has_many',
        collection?: true,
        klass: tags_klass  # Reuse for simplicity
      }),
      OpenStruct.new({
        name: :setting,
        macro: 'has_one',
        collection?: false,
        klass: tags_klass
      }),
      OpenStruct.new({
        name: :organisation,
        macro: 'belongs_to',
        collection?: false,
        klass: tags_klass
      }),
    ]
  end
  let(:encrypted_attributes) { [:password] }

  before do
    allow(subject).to receive(:columns).and_return(columns)
    allow(subject).to receive(:encrypted_attributes).and_return(encrypted_attributes)
    allow(subject).to receive(:reflect_on_all_associations).and_return(reflected_associations)
    subject.include(::Scry::Filterable)
  end

  # Helper methods to extract keys from new i18n structure
  def property_keys(permissions)
    permissions[:properties].map { |p| p[:key].to_sym }
  end

  def association_keys(permissions)
    permissions[:associations].map { |a| a[:key].to_sym }
  end

  describe '#filter_permissions' do
    it 'applies callback error policy for non-ActiveRecord filterable classes' do
      subject.add_filter_permission(:properties) { |_context| raise 'property discovery failed' }

      Scry.configuration.with_temporary_settings do |config|
        config.callback_error_policy = :raise
        expect { subject.filter_capabilities }
          .to raise_error(RuntimeError, 'property discovery failed')

        config.callback_error_policy = :match_none
        expect(subject.filter_capabilities)
          .to eq(Scry.empty_information.merge(error: true))
      end
    end

    context 'when permissions are set' do
      let(:permissions) { [] }

      before do
        permissions.each do |permission|
          subject.add_filter_permission(permission[:type], **permission[:options], &permission[:block])
        end
      end

      describe ':properties' do
        it 'returns all properties except the encrypted attributes' do
          expect(property_keys(subject.filter_capabilities)).to match_array(%i(id email first_name last_name date_of_birth address created_at updated_at))
        end

        context 'when permissions are reset' do
          let(:permissions) do
            [
              {
                type: :properties,
                options: {
                  list_type: :whitelist
                },
                block: ->(_auth_object) { %i(first_name last_name date_of_birth address) }
              }
            ]
          end

          before do
            subject.reset_filter_permissions(:properties)
          end

          it 'returns all properties except encrypted attributes' do
            expect(property_keys(subject.filter_capabilities)).to match_array(%i(id email first_name last_name date_of_birth address created_at updated_at))
          end
        end

        context 'when the list_type is :includelist' do
          let(:permissions) do
            [
              {
                type: :properties,
                options: {
                  list_type: :includelist
                },
                block: ->(_auth_object) { %i(id email fake_attribute) }
              }
            ]
          end

          # Because all properties are included by default the includelist does nothing
          it 'returns all properties except the encrypted attributes' do
            expect(property_keys(subject.filter_capabilities)).to match_array(%i(id email first_name last_name date_of_birth address created_at updated_at))
          end
        end

        context 'when the list_type is :excludelist' do
          let(:permissions) do
            [
              {
                type: :properties,
                options: {
                  list_type: :excludelist
                },
                block: ->(_auth_object) { %i(id email) }
              }
            ]
          end

          it 'returns the properties without those from the excludelist' do
            expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth address created_at updated_at))
          end
        end

        context 'when the list_type is :whitelist' do
          let(:permissions) do
            [
              {
                type: :properties,
                options: {
                  list_type: :whitelist
                },
                block: ->(_auth_object) { %i(first_name last_name date_of_birth address) }
              }
            ]
          end

          it 'returns only the whitelisted properties' do
            expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth address))
          end

          context 'when one of the properties is an encrypted attribute' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(first_name last_name date_of_birth address password) }
                }
              ]
            end

            it 'does not return the encrypted column' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth address))
            end
          end
        end

        context 'when the list_type is :blacklist' do
          let(:permissions) do
            [
              {
                type: :properties,
                options: {
                  list_type: :blacklist
                },
                block: ->(_auth_object) { %i(id email created_at updated_at) }
              }
            ]
          end

          it 'returns all properties except those from the blacklist and encrypted attributes' do
            expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth address))
          end
        end

        context 'when multiple permissions are set in order' do
          context ':includelist, :includelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(id first_name) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(id address) }
                }
              ]
            end

            it 'returns all properties except the encrypted attributes' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(id email first_name last_name date_of_birth address created_at updated_at))
            end
          end

          context ':includelist, :excludelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(id first_name) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(id email) }
                }
              ]
            end

            it 'returns all properties except the excluded and encrypted attributes' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth address created_at updated_at))
            end
          end

          context ':includelist, :whitelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(id first_name) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(id email) }
                }
              ]
            end

            it 'returns only the whitelisted properties' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(id email))
            end
          end

          context ':includelist, :blacklist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(id first_name) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(id email) }
                }
              ]
            end

            it 'returns all properties except blacklist and encrypted attributes' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth address created_at updated_at))
            end
          end

          context ':excludelist, :excludelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(id first_name) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(id email) }
                }
              ]
            end

            it 'returns all properties except the excluded and encrypted attributes' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(last_name date_of_birth address created_at updated_at))
            end
          end

          context ':excludelist, :includelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(id first_name) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(id email) }
                }
              ]
            end

            it 'returns the properties not in the excludelist except those that were re-included' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(email last_name date_of_birth address created_at updated_at id))
            end
          end

          context ':excludelist, :whitelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(id first_name) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(id email first_name last_name) }
                }
              ]
            end

            it 'returns only properties from the whitelist that were not excluded' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(email last_name))
            end
          end

          context ':excludelist, :blacklist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(id first_name date_of_birth) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(id email first_name last_name) }
                }
              ]
            end

            it 'returns all properties except those from the blacklist, excludelist and encrypted attributes' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(address created_at updated_at))
            end
          end

          context ':whitelist, :whitelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(first_name last_name date_of_birth address) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(email first_name last_name date_of_birth) }
                }
              ]
            end

            it 'returns only properties in both whitelists' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth))
            end
          end

          context ':whitelist, :includelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(first_name last_name date_of_birth address) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(email first_name last_name date_of_birth) }
                }
              ]
            end

            it 'returns properties from the whitelist and those from the includelist' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth address email))
            end
          end

          context ':whitelist, :excludelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(first_name last_name date_of_birth address) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(email first_name last_name date_of_birth) }
                }
              ]
            end

            it 'returns only properties from the whitelist and not the excludelist' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(address))
            end
          end

          context ':whitelist, :blacklist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(first_name last_name date_of_birth address) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(email first_name last_name date_of_birth) }
                }
              ]
            end

            it 'returns only properties that are in the whitelist and not in the blacklist or encrypted' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(address))
            end
          end

          context ':blacklist, :blacklist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(id email created_at updated_at) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(id address) }
                }
              ]
            end

            it 'returns only properties not in the either blacklists' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth))
            end
          end

          context ':blacklist, :includelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(id email created_at updated_at address) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(id first_name address) }
                }
              ]
            end

            it 'returns properties not in the blacklist and those in the includelist' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth id address))
            end
          end

          context ':blacklist, :excludelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(id email created_at updated_at) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(id address) }
                }
              ]
            end

            it 'returns properties not in the blacklist and not in the excludelist' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name last_name date_of_birth))
            end
          end

          context ':blacklist, :whitelist' do
            let(:permissions) do
              [
                {
                  type: :properties,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(id email created_at updated_at) }
                },
                {
                  type: :properties,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(id email first_name address) }
                }
              ]
            end

            it 'returns properties in the whitelist but not in the blacklist' do
              expect(property_keys(subject.filter_capabilities)).to match_array(%i(first_name address))
            end
          end
        end
      end

      describe ':associations' do
        it 'returns all associations' do
          expect(association_keys(subject.filter_capabilities)).to match_array(%i(tags roles setting organisation))
        end

        context 'when permissions are reset' do
          let(:permissions) do
            [
              {
                type: :associations,
                options: {
                  list_type: :whitelist
                },
                block: ->(_auth_object) { %i(roles) }
              }
            ]
          end

          before do
            subject.reset_filter_permissions(:associations)
          end

          it 'returns all associations' do
            expect(association_keys(subject.filter_capabilities)).to match_array(%i(tags roles setting organisation))
          end
        end

        context 'when the list_type is :includelist' do
          let(:permissions) do
            [
              {
                type: :associations,
                options: {
                  list_type: :includelist
                },
                block: ->(_auth_object) { %i(roles tags fake_association) }
              }
            ]
          end

          # Because all associations are included by default the includelist does nothing
          it 'returns all associations' do
            expect(association_keys(subject.filter_capabilities)).to match_array(%i(tags roles setting organisation))
          end
        end

        context 'when the list_type is :excludelist' do
          let(:permissions) do
            [
              {
                type: :associations,
                options: {
                  list_type: :excludelist
                },
                block: ->(_auth_object) { %i(tags setting) }
              }
            ]
          end

          it 'returns the associations without those from the excludelist' do
            expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles organisation))
          end
        end

        context 'when the list_type is :whitelist' do
          let(:permissions) do
            [
              {
                type: :associations,
                options: {
                  list_type: :whitelist
                },
                block: ->(_auth_object) { %i(tags setting) }
              }
            ]
          end

          it 'returns only the whitelisted associations' do
            expect(association_keys(subject.filter_capabilities)).to match_array(%i(tags setting))
          end
        end

        context 'when the list_type is :blacklist' do
          let(:permissions) do
            [
              {
                type: :associations,
                options: {
                  list_type: :blacklist
                },
                block: ->(_auth_object) { %i(tags setting) }
              }
            ]
          end

          it 'returns all associations except those from the blacklist' do
            expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles organisation))
          end
        end

        context 'when multiple permissions are set in order' do
          context ':includelist, :includelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(tags) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(setting) }
                }
              ]
            end

            it 'returns all associations' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(tags roles setting organisation))
            end
          end

          context ':includelist, :excludelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns all associations except the excluded and encrypted associations' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles setting))
            end
          end

          context ':includelist, :whitelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns only the whitelisted associations' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(tags organisation))
            end
          end

          context ':includelist, :blacklist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns all associations except blacklisted associations' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles setting))
            end
          end

          context ':excludelist, :excludelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(organisation) }
                }
              ]
            end

            it 'returns all associations except the excluded and encrypted associations' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles))
            end
          end

          context ':excludelist, :includelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns the associations not in the excludelist except those that were re-included' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles organisation tags))
            end
          end

          context ':excludelist, :whitelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns only associations from the whitelist that were not excluded' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(organisation))
            end
          end

          context ':excludelist, :blacklist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns all associations except those from the blacklist, or the excludelist' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles))
            end
          end

          context ':whitelist, :whitelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns only associations in both whitelists' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(tags))
            end
          end

          context ':whitelist, :includelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns associations from the whitelist and those from the includelist' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(tags setting organisation))
            end
          end

          context ':whitelist, :excludelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(tags setting organisation) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(tags roles) }
                }
              ]
            end

            it 'returns only associations from the whitelist and not the excludelist' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(setting organisation))
            end
          end

          context ':whitelist, :blacklist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(tags setting organisation) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(tags roles) }
                }
              ]
            end

            it 'returns only associations that are in the whitelist and not in the blacklist' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(setting organisation))
            end
          end

          context ':blacklist, :blacklist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns only associations not in the either blacklists' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles))
            end
          end

          context ':blacklist, :includelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :includelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns associations not in the blacklist and those in the includelist' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles organisation tags))
            end
          end

          context ':blacklist, :excludelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :excludelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns associations not in the blacklist and not in the excludelist' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(roles))
            end
          end

          context ':blacklist, :whitelist' do
            let(:permissions) do
              [
                {
                  type: :associations,
                  options: {
                    list_type: :blacklist
                  },
                  block: ->(_auth_object) { %i(tags setting) }
                },
                {
                  type: :associations,
                  options: {
                    list_type: :whitelist
                  },
                  block: ->(_auth_object) { %i(tags organisation) }
                }
              ]
            end

            it 'returns associations in the whitelist but not in the blacklist' do
              expect(association_keys(subject.filter_capabilities)).to match_array(%i(organisation))
            end
          end
        end
      end

      describe ':property_predicates' do
        let(:global_predicates) { %i(eq_nil not_eq_nil eq eq_any eq_all not_eq not_eq_any not_eq_all) }
        let(:textual_predicates) { %i(matches matches_any matches_all starts_with starts_with_any starts_with_all ends_with ends_with_any ends_with_all does_not_match does_not_match_any does_not_match_all does_not_start_with does_not_start_with_any does_not_start_with_all does_not_end_with does_not_end_with_any does_not_end_with_all) }
        let(:numerical_predicates) { %i(between not_between gt lt gteq lteq) }
        let(:temporal_predicates) { %i(within within_next within_previous not_within not_within_next not_within_previous) }
        let(:association_predicates) { %i() }
        let(:many_association_predicates) { %i(has_any not_has_any has_all not_has_all only_has_any only_has_all) }
        let(:single_association_predicates) { %i(has_any not_has_any) }

        let(:initial_property_predicates) do
          {
            id: global_predicates | numerical_predicates,
            email: global_predicates | textual_predicates,
            first_name: global_predicates | textual_predicates,
            last_name: global_predicates | textual_predicates,
            date_of_birth: global_predicates | numerical_predicates | temporal_predicates,
            address: global_predicates | textual_predicates,
            created_at: global_predicates | numerical_predicates | temporal_predicates,
            updated_at: global_predicates | numerical_predicates | temporal_predicates,
            tags: association_predicates | many_association_predicates,
            roles: association_predicates | many_association_predicates,
            setting: association_predicates | single_association_predicates,
            organisation: association_predicates | single_association_predicates
          }
        end

        it 'returns the globally set predicates that match the property types' do
          expect(subject.filter_capabilities).to include(property_predicates: initial_property_predicates)
        end

        context 'when permissions are set' do
          before do
            permissions.each do |permission|
              subject.add_filter_permission(permission[:type], **permission[:options], &permission[:block])
            end
          end

          context 'when permissions are reset' do
            let(:permissions) do
              [
                {
                  type: :property_predicates,
                  options: {
                    type: :whitelist
                  },
                  block: ->(_auth_object) do
                    {
                      first_name: %i(eq eq_any eq_all)
                    }
                  end
                }
              ]
            end

            before do
              subject.reset_filter_permissions(:property_predicates)
            end

            it 'returns the globally set predicates that match the attribute types' do
              expect(subject.filter_capabilities).to include(property_predicates: initial_property_predicates)
            end
          end

          context 'when the type is :property_predicates' do
            context 'when the list_type is :whitelist' do
              let(:permissions) do
                [
                  {
                    type: :property_predicates,
                    options: {
                      list_type: :whitelist
                    },
                    block: ->(_auth_object) do
                      {
                        id: :all,
                        first_name: %i(eq eq_any eq_all)
                      }
                    end
                  }
                ]
              end

              it 'returns only the whitelisted predicates for the attribute' do
                expect(subject.filter_capabilities).to include(property_predicates: {
                  id: global_predicates | numerical_predicates,
                  email: [],
                  first_name: %i(eq eq_any eq_all),
                  last_name: [],
                  date_of_birth: [],
                  address: [],
                  created_at: [],
                  updated_at: [],
                  tags: [],
                  roles: [],
                  setting: [],
                  organisation: []
                })
              end
            end

            context 'when the list_type is :blacklist' do
              let(:permissions) do
                [
                  {
                    type: :property_predicates,
                    options: {
                      list_type: :blacklist
                    },
                    block: ->(_auth_object) do
                      {
                        id: %i(eq eq_any eq_all),
                        first_name: :all
                      }
                    end
                  }
                ]
              end

              it 'returns all predicates for the properties except those from the blacklist' do
                expect(subject.filter_capabilities).to include(property_predicates: {
                  **initial_property_predicates,
                  id: (global_predicates | numerical_predicates) - %i(eq eq_any eq_all),
                  first_name: [],
                })
              end
            end

            context 'when the list_type is :includelist' do
              let(:permissions) do
                [
                  {
                    type: :property_predicates,
                    options: {
                      list_type: :includelist
                    },
                    block: ->(_auth_object) do
                      {
                        id: %i(eq eq_any eq_all),
                        first_name: %i(eq eq_any eq_all fake_predicate),
                        fake_attribute: %i(eq eq_any eq_all)
                      }
                    end
                  }
                ]
              end

              it 'returns all predicates for the attribute' do
                expect(subject.filter_capabilities).to include(property_predicates: initial_property_predicates)
              end
            end

            context 'when the list_type is :excludelist' do
              let(:permissions) do
                [
                  {
                    type: :property_predicates,
                    options: {
                      list_type: :excludelist
                    },
                    block: ->(_auth_object) do
                      {
                        id: %i(eq eq_any eq_all),
                        first_name: :all
                      }
                    end
                  }
                ]
              end

              it 'returns all predicates for the properties except those excluded' do
                expect(subject.filter_capabilities).to include(property_predicates: {
                  **initial_property_predicates,
                  id: (global_predicates | numerical_predicates) - %i(eq eq_any eq_all),
                  first_name: [],
                })
              end
            end

            context 'when multiple permissions are set in order' do
              context ':whitelist, :includelist' do
                let(:permissions) do
                  [
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_any eq_all),
                          first_name: :all,
                          last_name: %i(eq eq_any eq_all)
                        }
                      end
                    },
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :includelist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(matches),
                          email: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that have been whitelisted or included' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    id: %i(eq eq_any eq_all),
                    last_name: %i(eq eq_any eq_all),
                    date_of_birth: [],
                    address: [],
                    created_at: [],
                    updated_at: [],
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':whitelist, :blacklist' do
                let(:permissions) do
                  [
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_any eq_all),
                          first_name: :all,
                          last_name: %i(eq eq_any eq_all)
                        }
                      end
                    },
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_any eq_all),
                          last_name: %i(eq),
                          email: %i(eq)
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were whitelisted and not blacklisted' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    id: [],
                    email: [],
                    first_name: global_predicates | textual_predicates,
                    last_name: %i(eq_any eq_all),
                    date_of_birth: [],
                    address: [],
                    created_at: [],
                    updated_at: [],
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':whitelist, :whitelist' do
                let(:permissions) do
                  [
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_any eq_all),
                          first_name: :all,
                          last_name: %i(eq eq_any eq_all)
                        }
                      end
                    },
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq matches),
                          first_name: :all,
                          last_name: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were whitelisted in both' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    id: %i(eq),
                    email: [],
                    first_name: global_predicates | textual_predicates,
                    last_name: %i(eq eq_any eq_all),
                    date_of_birth: [],
                    address: [],
                    created_at: [],
                    updated_at: [],
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':blacklist, :includelist' do
                let(:permissions) do
                  [
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_any eq_all),
                          first_name: :all,
                          last_name: %i(eq eq_any eq_all)
                        }
                      end
                    },
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :includelist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(matches),
                          last_name: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were not excluded or were included' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    id: (global_predicates | numerical_predicates) - %i(eq eq_any eq_all),
                    first_name: [],
                  })
                end
              end

              context ':blacklist, :blacklist' do
                let(:permissions) do
                  [
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_any eq_all),
                          email: :all,
                          first_name: :all,
                          last_name: %i(eq eq_any eq_all)
                        }
                      end
                    },
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_all matches),
                          first_name: %i(eq eq_any matches),
                          last_name: :all,
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were not in either blacklist' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    id: (global_predicates | numerical_predicates) - %i(eq eq_any eq_all matche),
                    email: [],
                    first_name: [],
                    last_name: []
                  })
                end
              end

              context ':blacklist, :whitelist' do
                let(:permissions) do
                  [
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_any eq_all),
                          email: :all,
                          first_name: :all,
                          last_name: %i(eq eq_any eq_all)
                        }
                      end
                    },
                    {
                      type: :property_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          id: %i(eq eq_any lt),
                          first_name: %i(eq eq_any matches),
                          last_name: :all,
                          date_of_birth: :all,
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were in the whitelist but not in the blacklist' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    id: %i(lt),
                    email: [],
                    first_name: [],
                    last_name: initial_property_predicates[:last_name] - %i(eq eq_any eq_all),
                    address: [],
                    created_at: [],
                    updated_at: [],
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end
            end
          end

          context 'when the type is :type_predicates' do
            context 'the list_type is :whitelist' do
              let(:permissions) do
                [
                  {
                    type: :type_predicates,
                    options: {
                      list_type: :whitelist
                    },
                    block: ->(_auth_object) do
                      {
                        string: %i(matches),
                        timestamp: :all
                      }
                    end
                  }
                ]
              end

              it 'returns only the whitelisted predicates for the attribute' do
                expect(subject.filter_capabilities).to include(property_predicates: {
                  **initial_property_predicates,
                  id: [],
                  email: %i(matches),
                  first_name: %i(matches),
                  last_name: %i(matches),
                  address: %i(matches),
                  tags: [],
                  roles: [],
                  setting: [],
                  organisation: []
                })
              end
            end

            context 'the list_type is :blacklist' do
              let(:permissions) do
                [
                  {
                    type: :type_predicates,
                    options: {
                      list_type: :blacklist
                    },
                    block: ->(_auth_object) do
                      {
                        string: %i(eq matches),
                        integer: %i(eq lt),
                        timestamp: :all
                      }
                    end
                  }
                ]
              end

              it 'returns all predicates for the properties except those from the blacklist' do
                expect(subject.filter_capabilities).to include(property_predicates: {
                  **initial_property_predicates,
                  id: (global_predicates | numerical_predicates) - %i(eq lt),
                  email: (global_predicates | textual_predicates) - %i(eq matches),
                  first_name: (global_predicates | textual_predicates) - %i(eq matches),
                  last_name: (global_predicates | textual_predicates) - %i(eq matches),
                  date_of_birth: [],
                  address: (global_predicates | textual_predicates) - %i(eq matches),
                  created_at: [],
                  updated_at: []
                })
              end
            end

            context 'the list_type is :includelist' do
              let(:permissions) do
                [
                  {
                    type: :type_predicates,
                    options: {
                      list_type: :includelist
                    },
                    block: ->(_auth_object) do
                      {
                        string: %i(matches fake_predicate),
                        timestamp: :all,
                        fake_attribute: %i(eq eq_any eq_all)
                      }
                    end
                  }
                ]
              end

              it 'returns all predicates for the attribute' do
                expect(subject.filter_capabilities).to include(property_predicates: initial_property_predicates)
              end
            end

            context 'the list_type is :excludelist' do
              let(:permissions) do
                [
                  {
                    type: :type_predicates,
                    options: {
                      list_type: :excludelist
                    },
                    block: ->(_auth_object) do
                      {
                        string: %i(eq matches),
                        integer: %i(eq lt),
                        timestamp: :all
                      }
                    end
                  }
                ]
              end

              it 'returns all predicates for the properties except those excluded' do
                expect(subject.filter_capabilities).to include(property_predicates: {
                  **initial_property_predicates,
                  id: (global_predicates | numerical_predicates) - %i(eq lt),
                  email: (global_predicates | textual_predicates) - %i(eq matches),
                  first_name: (global_predicates | textual_predicates) - %i(eq matches),
                  last_name: (global_predicates | textual_predicates) - %i(eq matches),
                  date_of_birth: [],
                  address: (global_predicates | textual_predicates) - %i(eq matches),
                  created_at: [],
                  updated_at: []
                })
              end
            end

            context 'when multiple permissions are set in order' do
              context ':whitelist, :includelist' do
                let(:permissions) do
                  [
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(matches),
                          timestamp: :all
                        }
                      end
                    },
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :includelist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(eq),
                          integer: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that have been whitelisted or included' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    email: %i(matches eq),
                    first_name: %i(matches eq),
                    last_name: %i(matches eq),
                    address: %i(matches eq),
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':whitelist, :blacklist' do
                let(:permissions) do
                  [
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(eq eq_any matches),
                          timestamp: :all,
                          integer: %i(eq eq_any)
                        }
                      end
                    },
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(matches),
                          integer: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were whitelisted and not blacklisted' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    id: [],
                    email: %i(eq eq_any),
                    first_name: %i(eq eq_any),
                    last_name: %i(eq eq_any),
                    address: %i(eq eq_any),
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':whitelist, :whitelist' do
                let(:permissions) do
                  [
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(eq eq_any matches),
                          timestamp: :all,
                          integer: %i(eq eq_any)
                        }
                      end
                    },
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(matches),
                          integer: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were whitelisted in both' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    id: %i(eq eq_any),
                    email: %i(matches),
                    first_name: %i(matches),
                    last_name: %i(matches),
                    date_of_birth: [],
                    address: %i(matches),
                    created_at: [],
                    updated_at: [],
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':blacklist, :includelist' do
                let(:permissions) do
                  [
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(eq eq_any matches),
                          timestamp: :all,
                          integer: %i(eq eq_any)
                        }
                      end
                    },
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :includelist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(matches),
                          integer: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were not excluded or were included' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    email: (global_predicates | textual_predicates) - %i(eq eq_any matches) + %i(matches),
                    first_name: (global_predicates | textual_predicates) - %i(eq eq_any matches) + %i(matches),
                    last_name: (global_predicates | textual_predicates) - %i(eq eq_any matches) + %i(matches),
                    date_of_birth: [],
                    address: (global_predicates | textual_predicates) - %i(eq eq_any matches) + %i(matches),
                    created_at: [],
                    updated_at: []
                  })
                end
              end

              context ':blacklist, :blacklist' do
                let(:permissions) do
                  [
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(eq eq_any matches),
                          timestamp: :all,
                          integer: %i(eq eq_any)
                        }
                      end
                    },
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(matches eq_all),
                          integer: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were not in either blacklist' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    id: [],
                    email: (global_predicates | textual_predicates) - %i(eq eq_any eq_all matches),
                    first_name: (global_predicates | textual_predicates) - %i(eq eq_any eq_all matches),
                    last_name: (global_predicates | textual_predicates) - %i(eq eq_any eq_all matches),
                    date_of_birth: [],
                    address: (global_predicates | textual_predicates) - %i(eq eq_any eq_all matches),
                    created_at: [],
                    updated_at: []
                  })
                end
              end

              context ':blacklist, :whitelist' do
                let(:permissions) do
                  [
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(eq eq_any matches),
                          timestamp: :all,
                          integer: %i(eq eq_any)
                        }
                      end
                    },
                    {
                      type: :type_predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        {
                          string: %i(matches eq_all),
                          integer: :all
                        }
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were in the whitelist but not in the blacklist' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    id: (global_predicates | numerical_predicates) - %i(eq eq_any),
                    email: %i(eq_all),
                    first_name: %i(eq_all),
                    last_name: %i(eq_all),
                    date_of_birth: [],
                    address: %i(eq_all),
                    created_at: [],
                    updated_at: [],
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end
            end
          end

          context 'when the type is :predicates' do
            context 'the list_type is :includelist' do
              let(:permissions) do
                [
                  {
                    type: :predicates,
                    options: {
                      list_type: :includelist
                    },
                    block: ->(_auth_object) do
                      %i(eq eq_any eq_all lt matches fake_predicate)
                    end
                  }
                ]
              end

              it 'returns all predicates for all the properties' do
                expect(subject.filter_capabilities).to include(property_predicates: initial_property_predicates)
              end
            end

            context 'the list_type is :whitelist' do
              let(:permissions) do
                [
                  {
                    type: :predicates,
                    options: {
                      list_type: :whitelist
                    },
                    block: ->(_auth_object) do
                      %i(eq eq_any eq_all lt matches)
                    end
                  }
                ]
              end

              it 'returns only the whitelisted predicates for the attribute' do
                expect(subject.filter_capabilities).to include(property_predicates: {
                  id: %i(eq eq_any eq_all lt),
                  email: %i(eq eq_any eq_all matches),
                  first_name: %i(eq eq_any eq_all matches),
                  last_name: %i(eq eq_any eq_all matches),
                  date_of_birth: %i(eq eq_any eq_all lt),
                  address: %i(eq eq_any eq_all matches),
                  created_at: %i(eq eq_any eq_all lt),
                  updated_at: %i(eq eq_any eq_all lt),
                  tags: [],
                  roles: [],
                  setting: [],
                  organisation: []
                })
              end
            end

            context 'the list_type is :blacklist' do
              let(:permissions) do
                [
                  {
                    type: :predicates,
                    options: {
                      list_type: :blacklist
                    },
                    block: ->(_auth_object) do
                      %i(eq eq_any eq_all lt matches)
                    end
                  }
                ]
              end

              it 'returns all predicates for the properties except those from the blacklist' do
                expect(subject.filter_capabilities).to include(property_predicates: {
                  **initial_property_predicates,
                  id: initial_property_predicates[:id] - %i(eq eq_any eq_all lt),
                  email: initial_property_predicates[:email] - %i(eq eq_any eq_all matches),
                  first_name: initial_property_predicates[:first_name] - %i(eq eq_any eq_all matches),
                  last_name: initial_property_predicates[:last_name] - %i(eq eq_any eq_all matches),
                  date_of_birth: initial_property_predicates[:date_of_birth] - %i(eq eq_any eq_all lt),
                  address: initial_property_predicates[:address] - %i(eq eq_any eq_all matches),
                  created_at: initial_property_predicates[:created_at] - %i(eq eq_any eq_all lt),
                  updated_at: initial_property_predicates[:updated_at] - %i(eq eq_any eq_all lt),
                  organisation: initial_property_predicates[:organisation] - %i(eq eq_any eq_all),
                  setting: initial_property_predicates[:setting] - %i(eq eq_any eq_all),
                })
              end
            end

            context 'when multiple permissions are set in order' do
              context ':whitelist, :includelist' do
                let(:permissions) do
                  [
                    {
                      type: :predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        %i(eq eq_any eq_all lt matches)
                      end
                    },
                    {
                      type: :predicates,
                      options: {
                        list_type: :includelist
                      },
                      block: ->(_auth_object) do
                        %i(gt matches_any)
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that have been whitelisted or included' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    id: %i(eq eq_any eq_all lt gt),
                    email: %i(eq eq_any eq_all matches matches_any),
                    first_name: %i(eq eq_any eq_all matches matches_any),
                    last_name: %i(eq eq_any eq_all matches matches_any),
                    date_of_birth: %i(eq eq_any eq_all lt gt),
                    address: %i(eq eq_any eq_all matches matches_any),
                    created_at: %i(eq eq_any eq_all lt gt),
                    updated_at: %i(eq eq_any eq_all lt gt),
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':whitelist, :blacklist' do
                let(:permissions) do
                  [
                    {
                      type: :predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        %i(eq eq_any eq_all lt matches)
                      end
                    },
                    {
                      type: :predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        %i(gt matches_any eq)
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were whitelisted and not blacklisted' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    id: %i(eq_any eq_all lt),
                    email: %i(eq_any eq_all matches),
                    first_name: %i(eq_any eq_all matches),
                    last_name: %i(eq_any eq_all matches),
                    date_of_birth: %i(eq_any eq_all lt),
                    address: %i(eq_any eq_all matches),
                    created_at: %i(eq_any eq_all lt),
                    updated_at: %i(eq_any eq_all lt),
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':whitelist, :whitelist' do
                let(:permissions) do
                  [
                    {
                      type: :predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        %i(eq eq_any eq_all lt matches)
                      end
                    },
                    {
                      type: :predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        %i(eq lt gt matches matches_any)
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were in both whitelists' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    id: %i(eq lt),
                    email: %i(eq matches),
                    first_name: %i(eq matches),
                    last_name: %i(eq matches),
                    date_of_birth: %i(eq lt),
                    address: %i(eq matches),
                    created_at: %i(eq lt),
                    updated_at: %i(eq lt),
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end

              context ':blacklist, :includelist' do
                let(:permissions) do
                  [
                    {
                      type: :predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        %i(eq eq_any eq_all lt matches)
                      end
                    },
                    {
                      type: :predicates,
                      options: {
                        list_type: :includelist
                      },
                      block: ->(_auth_object) do
                        %i(eq lt gt matches matches_all)
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were not excluded or were included' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    id: initial_property_predicates[:id] - %i(eq eq_any eq_all lt) + %i(eq lt),
                    email: initial_property_predicates[:email] - %i(eq eq_any eq_all matches) + %i(eq matches),
                    first_name: initial_property_predicates[:first_name] - %i(eq eq_any eq_all matches) + %i(eq matches),
                    last_name: initial_property_predicates[:last_name] - %i(eq eq_any eq_all matches) + %i(eq matches),
                    date_of_birth: initial_property_predicates[:date_of_birth] - %i(eq eq_any eq_all lt) + %i(eq lt),
                    address: initial_property_predicates[:address] - %i(eq eq_any eq_all matches) + %i(eq matches),
                    created_at: initial_property_predicates[:created_at] - %i(eq eq_any eq_all lt) + %i(eq lt),
                    updated_at: initial_property_predicates[:updated_at] - %i(eq eq_any eq_all lt) + %i(eq lt),
                    organisation: initial_property_predicates[:organisation],
                    setting: initial_property_predicates[:setting]
                  })
                end
              end

              context ':blacklist, :blacklist' do
                let(:permissions) do
                  [
                    {
                      type: :predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        %i(eq eq_any eq_all lt matches)
                      end
                    },
                    {
                      type: :predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        %i(eq eq_any eq_all gt matches_all)
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were not in either blacklist' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    **initial_property_predicates,
                    id: initial_property_predicates[:id] - %i(eq eq_any eq_all lt gt),
                    email: initial_property_predicates[:email] - %i(eq eq_any eq_all matches matches_all),
                    first_name: initial_property_predicates[:first_name] - %i(eq eq_any eq_all matches matches_all),
                    last_name: initial_property_predicates[:last_name] - %i(eq eq_any eq_all matches matches_all),
                    date_of_birth: initial_property_predicates[:date_of_birth] - %i(eq eq_any eq_all lt gt),
                    address: initial_property_predicates[:address] - %i(eq eq_any eq_all matches matches_all),
                    created_at: initial_property_predicates[:created_at] - %i(eq eq_any eq_all lt gt),
                    updated_at: initial_property_predicates[:updated_at] - %i(eq eq_any eq_all lt gt),
                    organisation: initial_property_predicates[:organisation] - %i(eq eq_any eq_all),
                    setting: initial_property_predicates[:setting] - %i(eq eq_any eq_all)
                  })
                end
              end

              context ':blacklist, :whitelist' do
                let(:permissions) do
                  [
                    {
                      type: :predicates,
                      options: {
                        list_type: :blacklist
                      },
                      block: ->(_auth_object) do
                        %i(eq lt matches)
                      end
                    },
                    {
                      type: :predicates,
                      options: {
                        list_type: :whitelist
                      },
                      block: ->(_auth_object) do
                        %i(eq eq_any eq_all lt gt matches matches_all)
                      end
                    }
                  ]
                end

                it 'returns attribute predicates that were in the whitelist but not in the blacklist' do
                  expect(subject.filter_capabilities).to include(property_predicates: {
                    id: %i(eq_any eq_all gt),
                    email: %i(eq_any eq_all matches_all),
                    first_name: %i(eq_any eq_all matches_all),
                    last_name: %i(eq_any eq_all matches_all),
                    date_of_birth: %i(eq_any eq_all gt),
                    address: %i(eq_any eq_all matches_all),
                    created_at: %i(eq_any eq_all gt),
                    updated_at: %i(eq_any eq_all gt),
                    tags: [],
                    roles: [],
                    setting: [],
                    organisation: []
                  })
                end
              end
            end
          end
        end
      end
    end
  end

  describe '#custom_property_filters' do
    let(:custom_property_filters) { [] }
    before do
      custom_property_filters.each do |pf|
        subject.add_custom_property_filter(&pf)
      end
    end

    describe ':custom_property_filters' do
      let(:permissions) do
        [
          {
            type: :properties,
            options: {
              list_type: :whitelist
            },
            block: ->(_auth_object) do
              %i(has_assets_requiring_service)
            end
          },
          {
            type: :property_predicates,
            options: {
              list_type: :whitelist
            },
            block: ->(_auth_object) do
              {
                has_assets_requiring_service: %i(eq_true eq_false)
              }
            end
          }
        ]
      end

      let(:custom_property_filters) do
        [
          ->(_auth_object) do
            {
              has_assets_requiring_service: {
                filter: {
                  type: 'association',
                  association: 'assets',
                  predicate: 'has_any',
                  scoping: {
                    type: 'property',
                    property: 'next_service',
                    predicate: 'within_next',
                    args: [1]
                  }
                },
                type: :boolean
              }
            }
          end
        ]
      end

      before do
        permissions.each do |permission|
          subject.add_filter_permission(permission[:type], **permission[:options], &permission[:block])
        end
      end

      it 'returns the custom property filters' do
        expect(subject.filter_capabilities).to include(property_predicates: {
          has_assets_requiring_service: %i(eq_true eq_false),
          organisation: [],
          setting: [],
          roles: [],
          tags: [],
        })
      end
    end

    context 'with i18n support' do
      it 'returns properties as array of hashes with keys and labels' do
        result = subject.filter_capabilities(nil, locale: :en)
        expect(result[:properties]).to be_an(Array)
        expect(result[:properties].first).to have_key(:key)
        expect(result[:properties].first).to have_key(:label)
      end

      it 'returns associations as array of hashes with keys and labels' do
        result = subject.filter_capabilities(nil, locale: :en)
        expect(result[:associations]).to be_an(Array)
        # Only check structure if there are associations
        if result[:associations].any?
          expect(result[:associations].first).to have_key(:key)
          expect(result[:associations].first).to have_key(:label)
        end
      end

      it 'returns property_predicates as hash' do
        result = subject.filter_capabilities(nil, locale: :en)
        expect(result[:property_predicates]).to be_a(Hash)
      end

      it 'returns predicates metadata hash' do
        result = subject.filter_capabilities(nil, locale: :en)
        expect(result[:predicates]).to be_a(Hash)
      end

      it 'predicate metadata contains normalized signature fields' do
        result = subject.filter_capabilities(nil, locale: :en)
        result[:predicates].each do |key, metadata|
          expect(metadata).to have_key(:label)
          expect(metadata).to include(:parameters, :arguments)
        end
      end

      it 'passes locale parameter to underlying methods' do
        permissions_instance = subject.scry_permissions
        expect(permissions_instance).to receive(:properties_with_labels).with(nil, locale: :es)
        expect(permissions_instance).to receive(:associations_with_labels).with(nil, locale: :es)
        expect(permissions_instance).to receive(:predicate_metadata).with(nil, locale: :es)

        subject.filter_capabilities(nil, locale: :es)
      end
    end
  end
end
