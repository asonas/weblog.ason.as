# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/dsql_bootstrap"

class DsqlBootstrapTest < Minitest::Test
  Result = Data.define(:ntuples)

  class Connection
    attr_reader :statements

    def initialize(role_exists: false, mapping_exists: false)
      @results = [Result.new(role_exists ? 1 : 0), Result.new(mapping_exists ? 1 : 0)]
      @statements = []
    end

    def exec(statement)
      @statements << statement.strip
    end

    def exec_params(statement, params)
      @statements << [statement, params]
      @results.shift
    end

    def escape_literal(value)
      "'#{value.gsub("'", "''")}'"
    end

    def close
      @statements << :closed
    end
  end

  class Connector
    def initialize(connection)
      @connection = connection
    end

    def connect(host:)
      raise "missing host" if host.empty?

      @connection
    end
  end

  def test_creates_role_mapping_schema_and_tables
    connection = Connection.new
    bootstrap(connection).run

    assert_includes connection.statements, "CREATE ROLE weblog_authoring WITH LOGIN"
    assert connection.statements.any? { |statement| statement.to_s.start_with?("AWS IAM GRANT") }
    assert connection.statements.any? { |statement| statement.to_s.include?("weblog_authoring.pages") }
    assert connection.statements.any? { |statement| statement.to_s.include?("weblog_authoring.links") }
    assert_equal :closed, connection.statements.last
  end

  def test_preserves_existing_role_and_mapping
    connection = Connection.new(role_exists: true, mapping_exists: true)
    bootstrap(connection).run

    refute_includes connection.statements, "CREATE ROLE weblog_authoring WITH LOGIN"
    refute connection.statements.any? { |statement| statement.to_s.start_with?("AWS IAM GRANT") }
  end

  private

  def bootstrap(connection)
    WeblogAuthoring::DsqlBootstrap.new(
      host: "cluster.dsql.ap-northeast-1.on.aws",
      runtime_role_arn: "arn:aws:iam::123456789012:role/runtime",
      connector: Connector.new(connection)
    )
  end
end
