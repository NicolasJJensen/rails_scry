# frozen_string_literal: true

module Scry
  class Diagnostic
    attr_reader :category, :code, :path, :message

    def initialize(category:, code:, path:, message:)
      @category = category.to_sym
      @code = code.to_sym
      @path = Immutable.copy(path).freeze
      @message = message.dup.freeze
      freeze
    end

    def to_h
      {category:, code:, path:, message:}.freeze
    end
  end
end
