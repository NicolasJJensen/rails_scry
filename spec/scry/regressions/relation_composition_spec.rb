require 'rails_helper'

RSpec.describe 'Relation composition and transforms' do
  around(:each) do |example|
    Scry.configuration.with_temporary_settings do |_cfg|
      original_user = User.scry_permissions.deep_dup(klass: User)
      original_account = Account.scry_permissions.deep_dup(klass: Account)
      original_org = Organisation.scry_permissions.deep_dup(klass: Organisation)
      original_tech = Technician.scry_permissions.deep_dup(klass: Technician)
      begin
        example.run
      ensure
        User.scry_permissions = original_user
        User.scry_permissions.clear_caches!
        Account.scry_permissions = original_account
        Account.scry_permissions.clear_caches!
        Organisation.scry_permissions = original_org
        Organisation.scry_permissions.clear_caches!
        Technician.scry_permissions = original_tech
        Technician.scry_permissions.clear_caches!
      end
    end
  end


  describe 'Group JOIN preservation with mixed children' do
    def user_with_emails(first_name, addresses)
      user = create(:user, first_name: first_name, emails_count: 0)
      addresses.each { |addr| user.emails << create(:email, address: addr) }
      user
    end

    it 'AND group with aggregate + property applies both JOIN and WHERE' do
      u1 = user_with_emails('Alice', %w[a@x.com b@x.com c@x.com])
      _u2 = user_with_emails('Alice', %w[one@x.com])
      _u3 = user_with_emails('Bob', %w[a@x.com b@x.com c@x.com])

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [2] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to match_array([u1])
    end

    it 'OR group with aggregate + property preserves JOIN and applies OR on WHERE' do
      # Aggregate filters produce INNER JOINs (not WHERE), so the JOIN constrains
      # the result set independently of the OR'd WHERE clause from the property filter.
      # Records must satisfy the aggregate JOIN AND at least one WHERE condition.
      u1 = user_with_emails('Alice', %w[a@x.com b@x.com c@x.com])
      _u2 = user_with_emails('Bob', %w[a@x.com b@x.com c@x.com])
      _u3 = user_with_emails('Charlie', %w[one@x.com])

      filter = {
        type: 'group', predicate: 'or', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [2] },
          { type: 'property', property: 'first_name', predicate: 'eq', args: ['Alice'] }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      # The aggregate branch and the property branch are combined as an OR.
      # Both users with more than two emails satisfy the aggregate branch.
      expect(result).to match_array([u1, _u2])
    end
  end


  describe 'Association only_has_any/only_has_all reflection types' do
    it 'only_has_any with direct has_many (Organisation → users)' do
      org = create(:organisation)
      u1 = create(:user, organisation: org, first_name: 'A')
      u2 = create(:user, organisation: org, first_name: 'B')
      _u3 = create(:user, organisation: org, first_name: 'C')

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'users', predicate: 'only_has_any', args: [[u1.id, u2.id]] }
        ]
      }

      # org has u1, u2, u3 — not a subset of {u1, u2}, so org should NOT match
      result = Scry.filter_records_by(records: Organisation, filter: filter, context: nil).relation
      expect(result).not_to include(org)

      # Create an org whose users ARE a subset
      org2 = create(:organisation)
      create(:user, organisation: org2, first_name: 'D')

      # org2's user isn't in {u1, u2}, so also no match
      # Create org3 with only u4 who is in the provided set
      org3 = create(:organisation)
      u4 = create(:user, organisation: org3, first_name: 'E')

      filter2 = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'users', predicate: 'only_has_any', args: [[u4.id, u1.id]] }
        ]
      }
      result2 = Scry.filter_records_by(records: Organisation, filter: filter2, context: nil).relation
      expect(result2).to include(org3)
    end

    it 'only_has_all with HABTM (User → emails)' do
      e1 = create(:email, address: 'a@x.com')
      e2 = create(:email, address: 'b@x.com')
      e3 = create(:email, address: 'c@x.com')

      u1 = create(:user, emails_count: 0)
      u1.emails << [e1, e2]

      u2 = create(:user, emails_count: 0)
      u2.emails << [e1, e2, e3]

      u3 = create(:user, emails_count: 0)
      u3.emails << [e1]

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'emails', predicate: 'only_has_all', args: [[e1.id, e2.id]] }
        ]
      }

      # u1 has exactly {e1,e2} → matches (count==2, all in set)
      # u2 has {e1,e2,e3} → no match (count==3 != 2)
      # u3 has {e1} → no match (count==1 != 2)
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to match_array([u1])
    end

    it 'only_has_any with has_many :through (Technician → jobs)' do
      tech1 = Technician.create!(name: 'T1', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
      tech2 = Technician.create!(name: 'T2', max_daily_hours: 8, active: true, skills: [], certifications: [], work_hours: {})
      j1 = Job.create!(title: 'J1', duration_hours: 2, priority: 1, crew_size: 1)
      j2 = Job.create!(title: 'J2', duration_hours: 3, priority: 2, crew_size: 1)
      j3 = Job.create!(title: 'J3', duration_hours: 1, priority: 1, crew_size: 1)
      ScheduleAssignment.create!(technician: tech1, job: j1)
      ScheduleAssignment.create!(technician: tech2, job: j1)
      ScheduleAssignment.create!(technician: tech2, job: j3)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'jobs', predicate: 'only_has_any', args: [[j1.id, j2.id]] }
        ]
      }

      # tech1 has {j1} — subset of {j1,j2} → match
      # tech2 has {j1,j3} — j3 not in set → no match
      result = Scry.filter_records_by(records: Technician, filter: filter, context: nil).relation
      expect(result).to match_array([tech1])
    end

    it 'has_any with has_one (Account → primary_user)' do
      acc1 = Account.create!(username: 'acct1', password: 'x')
      acc2 = Account.create!(username: 'acct2', password: 'x')
      acc3 = Account.create!(username: 'acct3', password: 'x')

      u1 = create(:user, account: acc1)
      _u2 = create(:user, account: acc2)

      # acc3 has no primary_user (no user with account_id = acc3.id)

      # Allow primary_user association on Account
      Account.add_filter_permission(:associations) { |_ctx| [:primary_user] }
      Account.scry_permissions.clear_caches!

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'primary_user', predicate: 'has_any', args: [[u1.id]] }
        ]
      }

      result = Scry.filter_records_by(records: Account, filter: filter, context: nil).relation
      expect(result).to match_array([acc1])
    end
  end


  describe 'only_has_any with empty array' do
    it 'returns no records when given empty value array' do
      u1 = create(:user, emails_count: 0)
      e1 = create(:email, address: 'a@x.com')
      u1.emails << e1

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'association', association: 'emails', predicate: 'only_has_any', args: [[]] }
        ]
      }

      # only_has_any([]) means "user's emails are a subset of {}" — impossible for any user with emails
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).not_to include(u1)
    end
  end


  describe 'Group with all children returning nil' do
    it 'returns original records when all child filters are invalid' do
      u1 = create(:user)
      u2 = create(:user)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'nonexistent_column', predicate: 'eq', args: ['x'] },
          { type: 'property', property: 'also_nonexistent', predicate: 'eq', args: ['y'] }
        ]
      }

      # All children return nil → Group returns nil → filter_records_by falls back to original records
      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(u1, u2)
    end
  end


  describe 'Aggregate with nil scoping' do
    def user_with_emails(addresses)
      user = create(:user, emails_count: 0)
      addresses.each { |addr| user.emails << create(:email, address: addr) }
      user
    end

    it 'runs aggregate without scoping when scoping is nil' do
      u1 = user_with_emails(%w[a@x.com b@x.com c@x.com])
      _u2 = user_with_emails(%w[one@x.com])

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [2], scoping: nil }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to match_array([u1])
    end
  end


  describe 'Negation with empty WHERE clause' do
    def user_with_emails(addresses)
      user = create(:user, emails_count: 0)
      addresses.each { |addr| user.emails << create(:email, address: addr) }
      user
    end

    it 'negates an aggregate filter using LEFT JOIN fallback' do
      u1 = user_with_emails(%w[a@x.com b@x.com c@x.com])
      u2 = user_with_emails(%w[one@x.com])

      # Negate: NOT (count > 2) → users with 2 or fewer emails
      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'aggregate', association: 'emails', aggregate: 'count', predicate: 'gt', args: [2], negate: true }
        ]
      }

      result = Scry.filter_records_by(records: User, filter: filter, context: nil).relation
      expect(result).to include(u2)
      expect(result).not_to include(u1)
    end
  end


  describe 'Caller relation preservation through filtering' do
    it 'preserves ORDER BY and LIMIT through filter pipeline' do
      _u1 = create(:user, first_name: 'Charlie')
      u2 = create(:user, first_name: 'Alice')
      _u3 = create(:user, first_name: 'Bob')

      relation = User.order(:first_name).limit(2)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'active', predicate: 'eq', args: [true] }
        ]
      }

      result = Scry.filter_records_by(records: relation, filter: filter, context: nil).relation
      expect(result.limit_value).to eq(2)
      expect(result.order_values).to be_present
      # First result should be Alice (alphabetical order)
      expect(result.first).to eq(u2)
    end

    it 'preserves OFFSET through filter pipeline' do
      _u1 = create(:user, first_name: 'Alice')
      u2 = create(:user, first_name: 'Bob')
      _u3 = create(:user, first_name: 'Charlie')

      relation = User.order(:first_name).offset(1).limit(1)

      filter = {
        type: 'group', predicate: 'and', filters: [
          { type: 'property', property: 'active', predicate: 'eq', args: [true] }
        ]
      }

      result = Scry.filter_records_by(records: relation, filter: filter, context: nil).relation
      expect(result.offset_value).to eq(1)
      expect(result.limit_value).to eq(1)
      # Should skip Alice, return Bob
      expect(result.first).to eq(u2)
    end
  end


  describe 'Transform specificity' do
    it 'predicate-specific transform runs before global transform' do
      applied = []

      # Global transform (no only:)
      User.add_filter_transform(:first_name, on: :attribute) do |node, _ctx|
        applied << :global
        node
      end

      # Predicate-specific transform (only: [:eq])
      User.add_filter_transform(:first_name, only: [:eq], on: :attribute) do |node, _ctx|
        applied << :predicate
        node
      end

      User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[eq] } }

      create(:user, first_name: 'Test')
      filter = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'eq', args: ['Test'] }
      ] }

      Scry.filter_records_by(records: User, filter: filter, context: nil).relation.to_a
      expect(applied).to eq([:predicate, :global])
    end

    it 'transform with except: skips excluded predicates' do
      transform_ran = false

      User.add_filter_transform(:first_name, only: [:textual], except: [:eq]) do |node, _ctx|
        transform_ran = true
        Arel::Nodes::NamedFunction.new('LOWER', [node])
      end

      User.add_filter_permission(:property_predicates) { |_ctx| { first_name: %i[eq matches] } }

      u = create(:user, first_name: 'Test')

      # eq should NOT trigger the transform (excluded by except:)
      filter_eq = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'eq', args: ['Test'] }
      ] }
      Scry.filter_records_by(records: User, filter: filter_eq, context: nil).relation.to_a
      expect(transform_ran).to be false

      # matches SHOULD trigger the transform (textual type, not excluded)
      filter_matches = { type: 'group', predicate: 'and', filters: [
        { type: 'property', property: 'first_name', predicate: 'matches', args: ['test'] }
      ] }
      result = Scry.filter_records_by(records: User, filter: filter_matches, context: nil).relation
      expect(transform_ran).to be true
      expect(result).to include(u)
    end
  end
end
