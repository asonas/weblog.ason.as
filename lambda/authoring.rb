# frozen_string_literal: true

require "pathname"

require "weblog_authoring/dsql_database"
require "weblog_authoring/lambda_api"

module WeblogAuthoring
  module LambdaHandler
    module_function

    def call(event:, context:) # rubocop:disable Lint/UnusedMethodArgument
      api.call(event)
    end

    def api
      @api ||= LambdaApi.new(
        database: DsqlDatabase.new(
          host: ENV.fetch("DSQL_HOST"),
          content_dir: Pathname("/tmp/content")
        )
      )
    end
  end
end
