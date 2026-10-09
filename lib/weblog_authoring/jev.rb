# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "parameter_extension"

module WeblogAuthoring
  class Jev
    class Unavailable < StandardError; end

    ENDPOINT = URI("https://api.typesafe.ai/v1/systemone")
    MODEL = "jev-1.13.0"

    def initialize(api_key: ENV["TYPESAFE_API_KEY"], secret_id: ENV["TYPESAFE_SECRET_ID"], secret_client: ParameterExtension.new, http: Net::HTTP)
      @api_key = api_key
      @secret_id = secret_id
      @secret_client = secret_client
      @http = http
    end

    def configured?
      !@api_key.to_s.strip.empty? || !@secret_id.to_s.strip.empty?
    end

    def evaluate(state:, questions:)
      raise Unavailable, "候補の確認を利用できません" unless configured?

      request = Net::HTTP::Post.new(ENDPOINT)
      if !@secret_id.to_s.strip.empty? && !@secret_loaded
        begin
          @api_key = @secret_client.get_parameter(name: "/#{@secret_id.delete_prefix('/')}", with_decryption: true).parameter.value
        rescue IOError, SystemCallError, Timeout::Error, RuntimeError, JSON::ParserError, KeyError
          raise Unavailable, "候補の確認を利用できません。時間をおいてお試しください"
        end
        @secret_loaded = true
      end
      raise Unavailable, "候補の確認を利用できません" if @api_key.to_s.strip.empty?

      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(model: MODEL, state:, questions:)
      response = @http.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true,
        open_timeout: 3, read_timeout: 20, write_timeout: 5) { |http| http.request(request) }
      raise Unavailable, "候補の確認を利用できません。時間をおいてお試しください" unless response.is_a?(Net::HTTPSuccess)

      result = JSON.parse(response.body)
      answers = result.fetch("answers")
      raise Unavailable, "候補の判定結果を読み取れませんでした" unless answers.is_a?(Hash)

      answers
    rescue JSON::ParserError, KeyError, TypeError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Unavailable, "候補の確認に失敗しました。時間をおいてお試しください"
    end
  end
end
