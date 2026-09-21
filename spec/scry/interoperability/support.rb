require 'rails_helper'

module InteroperabilityModels
  class ActiveUser < User
    default_scope { where(active: true) }
  end

  class Organisation < ::Organisation
    has_many :active_users, -> { where(active: true) }, class_name: 'User', foreign_key: :organisation_id
    has_many :visible_users, class_name: 'InteroperabilityModels::ActiveUser', foreign_key: :organisation_id
    has_many :children, class_name: 'InteroperabilityModels::Organisation', foreign_key: :parent_id
    has_many :named_users, class_name: 'User', primary_key: :name, foreign_key: :last_name
  end

  class User < ::User
    belongs_to :organisation, class_name: 'InteroperabilityModels::Organisation'
    has_many :organisation_assets, through: :organisation, source: :assets
  end
end

module InteroperabilityFilters
  def group(*children, predicate: 'and', negate: false)
    { type: 'group', predicate: predicate, filters: children, negate: negate }
  end

  def property(name, predicate, *args, **options)
    { type: 'property', property: name, predicate: predicate, args: args, **options }
  end

  def association(name, predicate, *args, **options)
    { type: 'association', association: name, predicate: predicate, args: args, **options }
  end

  def aggregate(name, predicate, *args, **options)
    { type: 'aggregate', association: name, aggregate: 'count', predicate: predicate, args: args, **options }
  end

  def apply(scope, *children, **options)
    Scry.filter_records_by(records: scope, context: nil, filter: group(*children, **options)).relation
  end
end

RSpec.configure do |config|
  config.include InteroperabilityFilters, interoperability: true
  config.around(:each, interoperability: true) do |example|
    originals = [User, Technician, Job, Account, Organisation].to_h do |model|
      [model, model.scry_permissions.deep_dup(klass: model)]
    end
    Scry.configuration.with_temporary_settings do
      example.run
    end
  ensure
    originals&.each { |model, permissions| model.scry_permissions = permissions }
    Scry.clear_thread_caches!
  end
end
