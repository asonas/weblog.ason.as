# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module WeblogAuthoring
  class MatrixNotifier
    class NetHttpRequest
      def call(uri:, headers:, body:)
        request = Net::HTTP::Put.new(uri, headers)
        request.body = body
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end
        { status: Integer(response.code) }
      end
    end

    def initialize(secret_loader:, request: NetHttpRequest.new)
      @secret_loader = secret_loader
      @request = request
    end

    def call(event)
      config = @secret_loader.call
      event.fetch("Records").each do |record|
        raise ArgumentError, "unsupported notification event" unless record["EventSource"] == "aws:sns"

        notification = record.fetch("Sns")
        alarm = JSON.parse(notification.fetch("Message"))
        send_message(config:, message_id: notification.fetch("MessageId"), alarm:)
      end
      { "notified" => event.fetch("Records").length }
    end

    private

    def send_message(config:, message_id:, alarm:)
      uri = matrix_uri(config, message_id)
      body = JSON.generate(
        "msgtype" => "m.text",
        "body" => message_body(alarm)
      )
      response = @request.call(
        uri:,
        headers: {
          "Authorization" => "Bearer #{config.fetch('access_token')}",
          "Content-Type" => "application/json",
        },
        body:
      )
      status = response.fetch(:status)
      raise "Matrix returned #{status}" unless (200..299).cover?(status)
    end

    def matrix_uri(config, message_id)
      uri = URI(config.fetch("homeserver_url"))
      raise ArgumentError, "Matrix homeserver must use HTTPS" unless uri.is_a?(URI::HTTPS)

      room_id = URI.encode_www_form_component(config.fetch("room_id"))
      transaction_id = URI.encode_www_form_component(message_id)
      prefix = uri.path.sub(%r{/+\z}, "")
      uri.path = "#{prefix}/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/#{transaction_id}"
      uri.query = nil
      uri.fragment = nil
      uri
    end

    def message_body(alarm)
      state = alarm.fetch("NewStateValue")
      transition = state == "OK" ? "復旧" : "障害"
      [
        "インボックス同期 #{transition}",
        "Alarm: #{alarm.fetch('AlarmName')}",
        "State: #{state}",
        "Reason: #{alarm.fetch('NewStateReason')}",
        alarm["AlarmDescription"],
      ].compact.join("\n")
    end
  end
end
