# frozen_string_literal: true

require "json"
require "pathname"

require "weblog_authoring/dsql_database"

module WeblogAuthoring
  module LambdaHandler
    module_function

    def call(event:, context:) # rubocop:disable Lint/UnusedMethodArgument
      database.healthy?
      {
        statusCode: 200,
        headers: { "content-type" => "application/json" },
        body: JSON.generate(status: "ok"),
      }
    end

    def database
      @database ||= DsqlDatabase.new(
        host: ENV.fetch("DSQL_HOST"),
        content_dir: Pathname("/tmp/content")
      )
    end
  end
end
