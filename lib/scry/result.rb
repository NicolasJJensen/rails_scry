# frozen_string_literal: true

module Scry
  class Result
    STATUSES = %i[success partial failed].freeze

    attr_reader :status, :relation, :diagnostics

    def self.success(relation)
      new(status: :success, relation:, diagnostics: [])
    end

    def self.partial(relation, diagnostics:)
      new(status: :partial, relation:, diagnostics:)
    end

    def self.failure(relation:, message:, category: :invalid_filter, code: :invalid_filter, path: [])
      diagnostic = Diagnostic.new(category:, code:, path:, message:)
      new(status: :failed, relation:, diagnostics: [diagnostic])
    end

    def initialize(status:, relation:, diagnostics: [])
      raise ArgumentError, "unknown filter result status: #{status.inspect}" unless STATUSES.include?(status.to_sym)
      unless relation.is_a?(ActiveRecord::Relation)
        raise ArgumentError, "filter result relation must be an ActiveRecord::Relation"
      end
      unless diagnostics.is_a?(Array) && diagnostics.all? { |diagnostic| diagnostic.is_a?(Diagnostic) }
        raise ArgumentError, 'filter result diagnostics must be an Array of Diagnostic objects'
      end
      if status.to_sym == :success && diagnostics.any?
        raise ArgumentError, 'successful filter results cannot include diagnostics'
      end
      if %i[partial failed].include?(status.to_sym) && diagnostics.empty?
        raise ArgumentError, "#{status} filter results must include diagnostics"
      end

      @status = status.to_sym
      @relation = relation
      @diagnostics = diagnostics.dup.freeze
      freeze
    end

    def success?
      status == :success
    end

    def partial?
      status == :partial
    end

    def failed?
      status == :failed
    end

    def with_relation(relation)
      self.class.new(status:, relation:, diagnostics:)
    end

  end
end
