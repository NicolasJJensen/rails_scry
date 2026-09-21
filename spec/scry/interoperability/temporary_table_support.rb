# frozen_string_literal: true

module InteroperabilityTemporaryTables
  def with_temporary_table(name, definition)
    connection = ActiveRecord::Base.connection
    quoted_name = connection.quote_table_name(name)
    connection.execute("CREATE TEMPORARY TABLE #{quoted_name} (#{definition}) ON COMMIT DROP")
    yield name
  ensure
    drop_temporary_table(connection, quoted_name)
  end

  def drop_temporary_table(connection, quoted_name)
    return unless connection && quoted_name

    connection.execute("DROP TABLE IF EXISTS #{quoted_name}")
  rescue ActiveRecord::StatementInvalid
    # A failed statement aborts the surrounding fixture transaction;
    # PostgreSQL drops the temporary table when that transaction rolls back.
  end

  def temporary_model(constant_name, table_name)
    klass = Class.new(ApplicationRecord)
    stub_const(constant_name, klass)
    klass.table_name = table_name
    klass
  end
end

RSpec.configure do |config|
  config.include InteroperabilityTemporaryTables, interoperability: true
end
