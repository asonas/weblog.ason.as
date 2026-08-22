# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module WeblogAuthoring
  class GitHubOAuthError < StandardError; end

  class GitHubOAuth
    AUTHORIZE_URL = "https://github.com/login/oauth/authorize"
    TOKEN_URL = URI("https://github.com/login/oauth/access_token")
    USER_URL = URI("https://api.github.com/user")

    def initialize(client_id:, client_secret:)
      @client_id = client_id
      @client_secret = client_secret
    end

    def authorization_url(redirect_uri:, state:, code_challenge:)
      query = URI.encode_www_form(
        client_id: @client_id,
        redirect_uri:,
        state:,
        code_challenge:,
        code_challenge_method: "S256"
      )
      "#{AUTHORIZE_URL}?#{query}"
    end

    def authenticate(code:, redirect_uri:, code_verifier:)
      token = exchange_code(code:, redirect_uri:, code_verifier:)
      fetch_user(token)
    end

    private

    def exchange_code(code:, redirect_uri:, code_verifier:)
      request = Net::HTTP::Post.new(TOKEN_URL)
      request["Accept"] = "application/json"
      request.set_form_data(
        client_id: @client_id,
        client_secret: @client_secret,
        code:,
        redirect_uri:,
        code_verifier:
      )
      payload = parse_json(Net::HTTP.start(TOKEN_URL.host, TOKEN_URL.port, use_ssl: true) { |http| http.request(request) })
      token = payload["access_token"]
      raise GitHubOAuthError, "GitHubからアクセストークンを取得できませんでした" unless token.is_a?(String) && !token.empty?

      token
    end

    def fetch_user(token)
      request = Net::HTTP::Get.new(USER_URL)
      request["Accept"] = "application/vnd.github+json"
      request["Authorization"] = "Bearer #{token}"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      payload = parse_json(Net::HTTP.start(USER_URL.host, USER_URL.port, use_ssl: true) { |http| http.request(request) })
      id = payload["id"]
      login = payload["login"]
      raise GitHubOAuthError, "GitHubユーザーを確認できませんでした" unless id.is_a?(Integer) && login.is_a?(String)

      { "id" => id, "login" => login }
    end

    def parse_json(response)
      raise GitHubOAuthError, "GitHub OAuthとの通信に失敗しました" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise GitHubOAuthError, "GitHub OAuthの応答を読み取れませんでした"
    end
  end
end
