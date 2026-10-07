# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/development_database"
require_relative "../../lib/weblog_authoring/writing_suggestions"

class WritingSuggestionsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("writing-suggestions")
    @database = WeblogAuthoring::DevelopmentDatabase.new(Pathname(@directory).join("articles.sqlite3"), content_dir: Pathname(@directory).join("content"))
    @database.setup!
    @page = @database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "Cloudflare", body: "クラウドフレアのキャッシュを使うと、記事の表示が速くなった。"))
    @service = WeblogAuthoring::WritingSuggestions.new(reader: @database, client: WeblogAuthoring::Jev.new(api_key: "test-key"))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def choice(value, probability = 0.95)
    { "type" => "choice", "choice" => value, "probabilities" => { value => probability }, "confidence" => 0.9 }
  end

  def with_api(&operation)
    requests = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      payload = JSON.parse(request.body)
      requests << payload
      answers = operation.call(payload)
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.body = JSON.generate("answers" => answers)
      response
    end
    http.define_singleton_method(:start) { |*_args, **_options, &block| block.call(http) }
    service = WeblogAuthoring::WritingSuggestions.new(reader: @database, client: WeblogAuthoring::Jev.new(api_key: "test-key", http:))
    [requests, service]
  end

  def test_returns_a_spelling_variant_and_past_evidence_with_utf16_offsets
    text = "𠮷野ではＣｌｏｕｄｆｌａｒｅのキャッシュを使い、記事の表示が速くなった。"
    requests, service = with_api do |payload|
      payload.fetch("questions").to_h do |key, _question|
        [key, key.start_with?("link_") ? choice("page_0") : choice("repeated")]
      end
    end
    result = service.call(text:, article_id: "draft")
    link = result.fetch("links").find { |item| item.fetch("text") == "Ｃｌｏｕｄｆｌａｒｅ" }
    assert_equal [5, 15], link.fetch("range")
    assert_equal "[[Cloudflare]]", link.fetch("replacement")
    assert_equal @page.id, result.fetch("related").first.fetch("article_id")
    assert_equal "repeated", result.fetch("related").first.fetch("relation")
    assert_includes result.fetch("related").first.fetch("excerpt"), "記事の表示が速くなった"
    assert_equal "jev-1.13.0", requests.first.fetch("model")
  end

  def test_code_links_and_urls_are_not_replaced_and_current_article_is_excluded
    text = "```ruby\nCloudflare\n```\n`Cloudflare` [[Cloudflare]] [Cloudflare](/Cloudflare) https://example.com/Cloudflare\n"
    requests, service = with_api { |_| {} }
    result = service.call(text:, article_id: @page.id)
    assert_empty result.fetch("links")
    assert_empty result.fetch("related")
    assert_empty requests
    service.call(text:, article_id: "draft")
    assert(requests.flat_map { |request| request.fetch("questions").keys }.none? { |key| key.start_with?("link_") })
  end

  def test_uncertain_or_unknown_answers_do_not_create_links_or_related_results
    _requests, service = with_api do |payload|
      payload.fetch("questions").to_h { |key, _| [key, choice(key.start_with?("link_") ? "invented-page" : "repeated", 0.4)] }
    end
    result = service.call(text: "Cloudflareのキャッシュで記事の表示が速くなった", article_id: "draft")
    assert_empty result.fetch("links")
    assert_empty result.fetch("related")
  end

  def test_unconfigured_service_and_invalid_inputs_do_not_call_the_provider
    service = WeblogAuthoring::WritingSuggestions.new(reader: @database, client: WeblogAuthoring::Jev.new(api_key: nil))
    assert_equal({ "enabled" => false, "links" => [], "related" => [] }, service.call(text: "Cloudflare", article_id: "draft"))
    assert_raises(ArgumentError) { service.call(text: "あ" * 8001, article_id: "draft") }
    assert_raises(ArgumentError) { service.call(text: nil, article_id: "draft") }
  end

  def test_transport_failures_do_not_expose_credentials_or_provider_response
    http = Object.new
    http.define_singleton_method(:start) { |*_args, **_options| raise IOError, "test-key secret response" }
    service = WeblogAuthoring::WritingSuggestions.new(reader: @database, client: WeblogAuthoring::Jev.new(api_key: "test-key", http:))
    error = assert_raises(WeblogAuthoring::Jev::Unavailable) { service.call(text: "Cloudflare", article_id: "draft") }
    refute_includes error.message, "test-key"
    refute_includes error.message, "secret response"
  end
end
