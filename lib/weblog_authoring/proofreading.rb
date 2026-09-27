# frozen_string_literal: true

require "json"
require "open3"
require "aws-sdk-lambda"

module WeblogAuthoring
  class Proofreading
    class Unavailable < StandardError; end

    def initialize(lambda_client: nil, function_name: nil)
      @lambda_client = lambda_client
      @function_name = function_name
    end

    def call(text)
      unless text.is_a?(String) && text.bytesize <= 1_000_000
        raise ArgumentError, "校正する本文は UTF-8 で 1 MB 以下の文字列にしてください"
      end
      payload = JSON.generate("text" => text)
      client = @lambda_client.respond_to?(:call) ? @lambda_client.call : @lambda_client
      if client
        response = client.invoke(function_name: @function_name, invocation_type: "RequestResponse", payload:)
        raise Unavailable, "文章を確認できませんでした" if response.function_error
        JSON.parse(response.payload.read)
      else
        script = File.expand_path("../../lambda/proofreading/local.mjs", __dir__)
        output, _error, status = Open3.capture3("node", script, stdin_data: payload)
        raise Unavailable, "文章を確認できませんでした" unless status.success?
        JSON.parse(output)
      end
    rescue Aws::Lambda::Errors::ServiceError, JSON::ParserError, Errno::ENOENT
      raise Unavailable, "文章を確認できませんでした"
    end
  end
end
