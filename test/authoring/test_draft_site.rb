# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/draft_site"
require "weblog_authoring/lambda_api"
require "weblog_authoring/development_database"

class DraftSiteTest < Minitest::Test
  def test_linked_topics_render_their_title_and_backlinks_in_the_public_shell
    Dir.mktmpdir("draft-site") do |directory|
      root = Pathname(directory)
      database = WeblogAuthoring::DevelopmentDatabase.new(root.join("articles.sqlite3"), content_dir: root.join("content"))
      database.setup!
      database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", title: "紹介記事", body: "[[KORG multi/poly]]"))
      s3 = Aws::S3::Client.new(stub_responses: true)
      s3.stub_responses(:get_object, body: File.read(File.expand_path("../../public.html", __dir__)))
      site = WeblogAuthoring::DraftSite.new(api: WeblogAuthoring::LambdaApi.new(database:), reader: database, s3_client: s3, bucket: "site", published: true)
      event = { "rawPath" => "/KORG%20multi%2Fpoly", "requestContext" => { "http" => { "method" => "GET" } } }

      response = site.call(event)
      assert_equal 200, response.fetch(:statusCode)
      html = response.fetch(:body)
      assert_includes html, '<h1 class="p-name">KORG multi/poly</h1>'
      assert_includes html, "href=\"/#{WeblogAuthoring.encoded_route('紹介記事')}\""
      assert_includes html, '/frontend/authoring/publicArticle.ts'
      assert_equal "static/authoring/public.html", s3.api_requests.last.fetch(:params).fetch(:key)
      assert_equal 404, site.call(event.merge("rawPath" => "/unknown")).fetch(:statusCode)
      assert_equal "", site.call(event.merge("requestContext" => { "http" => { "method" => "HEAD" } })).fetch(:body)
    end
  end
end
