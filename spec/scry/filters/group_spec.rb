require 'rails_helper'

RSpec.describe Scry::Filters::Group do
  describe 'filter class mapping' do
    it 'uses configuration.filter_class_mappings to resolve type' do
      # Create a simple OR group with a property and an association to ensure
      # both mappings are resolved without error
      org1 = create(:organisation)
      org2 = create(:organisation)
      u1 = create(:user, first_name: 'Alice', organisation: org1)
      u2 = create(:user, first_name: 'Bob', organisation: org2)

      filter = {
        type: 'group',
        predicate: 'or',
        filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] },
          { type: 'association', association: 'organisation', predicate: 'has_any', args: [[org2.id]] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to match_array([u1, u2])
    end

    it 'skips unknown filter types' do
      create(:user, first_name: 'Carol')
      create(:user, first_name: 'Dave')

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'unknown_type', property: 'first_name', predicate: 'eq', value: 'Carol' }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      # Unknown type is skipped, no children produce results, returns original records
      expect(result).to be_a(ActiveRecord::Relation)
    end

    it 'retains the authorized identity universe for a custom group subclass' do
      visible = create(:user, first_name: 'Visible')
      hidden = create(:user, first_name: 'Hidden')
      custom_group = Class.new(Scry::Filters::Group)
      filter = {
        type: 'group', predicate: 'and', filters: [{
          type: 'secure_group', predicate: 'and', value: [{
            type: 'group', predicate: 'and',
            filters: [{type: 'property', property: 'id', predicate: 'gteq', args: [0]}],
            order: [{property: 'id', direction: 'desc'}], limit: 1
          }]
        }]
      }

      Scry.configuration.with_temporary_settings do |config|
        config.register_filter(:secure_group, custom_group)
        result = Scry.filter_records_by(records: User.where(id: visible.id), filter:).relation

        expect(result.ids).to eq([visible.id])
        expect(result.ids).not_to include(hidden.id)
      end
    end
  end

  describe 'predicate validation' do
    it 'combines child relations for and/or correctly' do
      u1 = create(:user, first_name: 'Eve')
      u2 = create(:user, first_name: 'Evan')
      u3 = create(:user, first_name: 'Mallory')

      # OR
      or_filter = {
        type: 'group', predicate: 'or', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Eve'] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Evan'] }
        ]
      }
      expect(Scry.filter_records_by(records: User, filter: or_filter, context: nil).relation).to match_array([u1, u2])

      # AND (two mutually exclusive eqs should return empty)
      and_filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Eve'] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Evan'] }
        ]
      }
      expect(Scry.filter_records_by(records: User, filter: and_filter, context: nil).relation).to be_empty

      # AND (both true for Mallory using starts_with and ends_with)
      and_true = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'first_name', predicate: 'starts_with', args: ['Ma'] },
          { type: 'property', property: 'first_name', predicate: 'ends_with', args: ['ory'] }
        ]
      }
      expect(Scry.filter_records_by(records: User, filter: and_true, context: nil).relation).to match_array([u3])
    end

    it 'rejects invalid group predicate with a warning' do
      create(:user)
      filter = { type: 'group', predicate: 'xor', filters: [] }
      result = Scry::Filters::Group.new(model: User, filter:, context: nil).apply
      expect(result).to be_failed
    end

    it 'rejects invalid group predicate with non-empty children' do
      create(:user, first_name: 'Alice')
      filter = {
        type: 'group', predicate: 'xor', filters: [
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        ]
      }
      result = Scry::Filters::Group.new(model: User, filter:, context: nil).apply
      expect(result).to be_failed
    end

    it 'returns all records for empty AND group (identity)' do
      u1 = create(:user)
      filter = { type: 'group', predicate: 'and', filters: [] }
      result = Scry::Filters::Group.new(model: User, filter:, context: nil).apply
      expect(result.relation).to be_a(ActiveRecord::Relation)
      expect(result.relation).to include(u1)
    end

    it 'returns no records for empty OR group (annihilator)' do
      create(:user)
      filter = { type: 'group', predicate: 'or', filters: [] }
      result = Scry::Filters::Group.new(model: User, filter:, context: nil).apply
      expect(result.relation).to be_a(ActiveRecord::Relation)
      expect(result.relation).to be_empty
    end

    it 'rejects NOT as a group predicate (use negate flag instead)' do
      create(:user)
      filter = { type: 'group', predicate: 'not', filters: [] }
      result = Scry::Filters::Group.new(model: User, filter:, context: nil).apply
      expect(result).to be_failed
    end

    it 'skips nil child relations and combines the rest' do
      u1 = create(:user, first_name: 'Zed')
      _u2 = create(:user, first_name: 'Zoe')

      filter = {
        type: 'group', predicate: 'or', filters: [
          # Invalid property -> nil
          { type: 'property', property: 'unknown_prop', predicate: 'eq', args: ['noop'] },
          # Valid property
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Zed'] }
        ]
      }
      expect(Scry.filter_records_by(records: User, filter: filter, context: nil).relation).to match_array([u1])
    end
  end

  describe 'failed custom children' do
    let(:invalid_custom_filter) do
      Class.new(Scry::Filters::Base) do
        def apply
          Scry::Result.failure(
            relation: @scope.none,
            category: :invalid_filter,
            code: :custom_invalid,
            path: diagnostic_path,
            message: 'Scry: custom filter is invalid'
          )
        end
      end
    end

    before do
      stub_const('GroupSpecs::InvalidCustomFilter', invalid_custom_filter)
      Scry.configuration.register_filter(:invalid_custom, invalid_custom_filter)
    end

    [
      ['and', false, :all],
      ['or', false, :none],
      ['and', true, :none],
      ['or', true, :all]
    ].each do |predicate, negate, expected_scope|
      it "returns a failed result without partial selection for an invalid custom #{predicate} group with negate=#{negate}" do
        user = create(:user)
        result = Scry.filter_records_by(
          records: User.where(id: user.id),
          filter: {
            type: :group,
            predicate: predicate,
            negate: negate,
            filters: [{type: :invalid_custom}]
          }
        )

        expect(result).to be_failed
        expect(result.diagnostics).to contain_exactly(
          have_attributes(code: :custom_invalid, path: [:filters, 0])
        )
        if expected_scope == :all
          expect(result.relation).to contain_exactly(user)
        else
          expect(result.relation).to be_empty
        end
      end
    end
  end

  describe 'custom child compilation' do
    it 'lets a custom filter compose a registered child through Base#compile_nested_filter' do
      custom_filter = Class.new(Scry::Filters::Base) do
        def apply
          result = compile_nested_filter(filter[:child], path: [*diagnostic_path, :child])
          return result if result.failed?

          result.with_relation(source_relation.where(
            Scry::Compatibility.condition(result.relation, outer_relation: source_relation)
          ))
        end
      end
      stub_const('GroupSpecs::ComposingFilter', custom_filter)

      visible = create(:user, first_name: 'Visible')
      _other = create(:user, first_name: 'Other')
      Scry.configuration.register_filter(:composing, custom_filter)

      result = Scry.filter_records_by(
        records: User.where(id: visible.id),
        filter: {type: :composing, child: {type: :property, property: :first_name, predicate: :eq, args: ['Visible']}}
      )

      expect(result.relation).to contain_exactly(visible)
      expect(result.diagnostics).to be_empty
    end

    it 'returns child diagnostics with the custom child path' do
      custom_filter = Class.new(Scry::Filters::Base) do
        def apply
          compile_nested_filter(filter[:child], path: [*diagnostic_path, :child])
        end
      end
      stub_const('GroupSpecs::DiagnosticComposingFilter', custom_filter)
      Scry.configuration.register_filter(:diagnostic_composing, custom_filter)

      result = Scry.filter_records_by(
        records: User,
        filter: {type: :diagnostic_composing, child: {type: :unknown_filter}}
      )

      expect(result.diagnostics).to contain_exactly(
        have_attributes(code: :unknown_filter_type, path: [:child])
      )
    end

    %i[skip match_none].each do |policy|
      it "preserves partial child diagnostics and authorized rows under #{policy}" do
        Scry.configuration.with_temporary_settings do |config|
          custom_filter = Class.new(Scry::Filters::Base) do
            def apply
              result = compile_nested_filter(filter[:child], path: [*diagnostic_path, :child])
              return result if result.failed?

              result.with_relation(source_relation.where(
                Scry::Compatibility.condition(result.relation, outer_relation: source_relation)
              ))
            end
          end
          stub_const("GroupSpecs::PolicyComposingFilter#{policy}", custom_filter)
          config.register_filter(:policy_composing, custom_filter)
          config.invalid_filter_policy = policy

          matching = create(:user, first_name: "Policy match #{policy}")
          nonmatching = create(:user, first_name: "Policy other #{policy}")
          result = Scry.filter_records_by(
            records: User.where(id: [matching.id, nonmatching.id]),
            filter: {
              type: :policy_composing,
              child: {
                type: :group,
                predicate: :and,
                filters: [
                  { type: :property, property: :first_name, predicate: :eq, args: [matching.first_name] },
                  { type: :unknown_filter }
                ]
              }
            }
          )

          if policy == :skip
            expect(result).to be_partial
            expect(result.relation).to contain_exactly(matching)
          else
            expect(result).to be_failed
            expect(result.relation).to be_empty
          end
          expect(result.diagnostics).to contain_exactly(
            have_attributes(code: :unknown_filter_type, path: [:child, :filters, 1])
          )
        end
      end
    end

    it 'preserves partial child diagnostics and applies match-none before raising' do
      Scry.configuration.with_temporary_settings do |config|
        custom_filter = Class.new(Scry::Filters::Base) do
          def apply
            result = compile_nested_filter(filter[:child], path: [*diagnostic_path, :child])
            return result if result.failed?

            result.with_relation(source_relation.where(
              Scry::Compatibility.condition(result.relation, outer_relation: source_relation)
            ))
          end
        end
        stub_const('GroupSpecs::RaisePolicyComposingFilter', custom_filter)
        config.register_filter(:raise_policy_composing, custom_filter)
        config.invalid_filter_policy = :raise

        matching = create(:user, first_name: 'Raise policy match')
        nonmatching = create(:user, first_name: 'Raise policy other')
        expect {
          Scry.filter_records_by(
            records: User.where(id: [matching.id, nonmatching.id]),
            filter: {
              type: :raise_policy_composing,
              child: {
                type: :group,
                predicate: :and,
                filters: [
                  { type: :property, property: :first_name, predicate: :eq, args: [matching.first_name] },
                  { type: :unknown_filter }
                ]
              }
            }
          )
        }.to raise_error(Scry::FilterError) { |error|
          expect(error.result).to be_partial
          expect(error.result.relation).to contain_exactly(matching)
          expect(error.result.diagnostics).to contain_exactly(
            have_attributes(code: :unknown_filter_type, path: [:child, :filters, 1])
          )
        }
      end
    end

    %i[node_limit cycle].each do |mode|
      %i[skip match_none raise].each do |policy|
        it "applies #{policy} to a generated nested #{mode} diagnostic" do
          Scry.configuration.with_temporary_settings do |config|
            generated_filter = Class.new(Scry::Filters::Base) do
              define_method(:apply) do
                generated = if filter[:mode].to_sym == :cycle
                  value = {type: :group, predicate: :and, filters: []}
                  value[:filters] << value
                  value
                else
                  {
                    type: :group,
                    predicate: :and,
                    filters: Array.new(20) { {type: :property, property: :first_name, predicate: :eq, args: ['x']} }
                  }
                end
                compile_nested_filter(generated, path: [*diagnostic_path, :saved_filter])
              end
            end
            stub_const("GroupSpecs::Generated#{mode.to_s.capitalize}Filter", generated_filter)
            config.register_filter(:generated_safety, generated_filter)
            config.invalid_filter_policy = policy
            config.max_filter_nodes = 40

            matching = create(:user, first_name: "Generated #{mode} match")
            other = create(:user, first_name: "Generated #{mode} other")
            request = {
              type: :group,
              predicate: :and,
              filters: [
                {type: :property, property: :first_name, predicate: :eq, args: [matching.first_name]},
                {type: :generated_safety, mode:}
              ]
            }

            invoke = -> { Scry.filter_records_by(records: User.where(id: [matching.id, other.id]), filter: request) }
            if policy == :raise
              expect { invoke.call }.to raise_error(Scry::FilterError) { |error|
                expect(error.result).to be_partial
                expect(error.result.relation).to contain_exactly(matching)
                expect(error.result.diagnostics).to contain_exactly(
                  have_attributes(code: :invalid_filter, path: [:filters, 1, :saved_filter])
                )
              }
            else
              result = invoke.call
              expect(result).to public_send(policy == :skip ? :be_partial : :be_failed)
              expect(result.relation).to(policy == :skip ? contain_exactly(matching) : be_empty)
              expect(result.diagnostics).to contain_exactly(
                have_attributes(code: :invalid_filter, path: [:filters, 1, :saved_filter])
              )
            end
          end
        end
      end
    end
  end
end
