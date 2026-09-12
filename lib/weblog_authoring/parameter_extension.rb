# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module WeblogAuthoring
  class ParameterExtension
    Parameter = Data.define(:value)
    Response = Data.define(:parameter)

    def get_parameter(name:, with_decryption:)
      uri = URI("http://127.0.0.1:#{ENV.fetch('PARAMETERS_SECRETS_EXTENSION_HTTP_PORT', '2773')}/systemsmanager/parameters/get")
      uri.query = URI.encode_www_form(name:, withDecryption: with_decryption)
      request = Net::HTTP::Get.new(uri)
      request["X-Aws-Parameters-Secrets-Token"] = ENV.fetch("AWS_SESSION_TOKEN")
      # The extension is local; never forward the session token through an HTTP proxy.
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.open_timeout = 2
      http.read_timeout = 5
      response = http.start { |connection| connection.request(request) }
      raise "Parameter extension returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      Response.new(Parameter.new(JSON.parse(response.body).fetch("Parameter").fetch("Value")))
    end
  end
end
