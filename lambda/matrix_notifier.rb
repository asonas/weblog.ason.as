# frozen_string_literal: true

require "json"
require "aws-sdk-secretsmanager"

require "weblog_authoring/matrix_notifier"

module WeblogAuthoring
  module MatrixNotifierLambdaHandler
    module_function

    def call(event:, context:, notifier: nil) # rubocop:disable Lint/UnusedMethodArgument
      (notifier || default_notifier).call(event)
    end

    def default_notifier
      @default_notifier ||= MatrixNotifier.new(
        secret_loader: lambda do
          response = Aws::SecretsManager::Client.new.get_secret_value(
            secret_id: ENV.fetch("MATRIX_SECRET_ID")
          )
          JSON.parse(response.secret_string)
        end
      )
    end
    private_class_method :default_notifier
  end
end
