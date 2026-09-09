# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/development_database"
require "weblog_authoring/video_library"
require "weblog_authoring/lambda_api"
require "weblog_authoring/lambda_session"

class VideoLibraryTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("video-library")
    @time = Time.utc(2026, 9, 9)
    @database = WeblogAuthoring::DevelopmentDatabase.new(File.join(@directory, "db.sqlite3"), content_dir: @directory, clock: -> { @time })
    @database.setup!
    @s3 = Aws::S3::Client.new(region: "ap-northeast-1", credentials: Aws::Credentials.new("test", "test"), stub_responses: true)
    @s3.stub_responses(:head_object, content_type: "video/mp4", content_length: 1_000_000)
    @library = WeblogAuthoring::VideoLibrary.new(database: @database, s3_client: @s3, bucket: "assets")
    @payload = { "avc" => "/assets/uploads/2026/09/11111111-2222-3333-4444-555555555555.mp4",
                 "av1" => "/assets/uploads/2026/09/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.mp4",
                 "name" => "IMG_0010.MOV", "width" => 1920, "height" => 1080, "duration" => 33.44, }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_keeps_one_reusable_material_after_body_removal_and_inbox_retention
    item = @library.register(@payload)
    assert_equal 2_000_000, item.dig("payload", "size")
    assert_equal(@payload, item.fetch("payload").reject { |key, _| key == "size" })
    assert_equal item, @library.register(@payload)
    assert_equal(2, @s3.api_requests.count { |request| request.fetch(:operation_name) == :head_object })
    page = @database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "動画", body: ":::video #{@payload.fetch('avc')} #{@payload.fetch('av1')} 1920x1080 :::"))
    @database.save(WeblogAuthoring::SaveRequest.new(page_id: page.id, page_type: "named", name: "動画", body: "本文"))
    @time += 30 * 24 * 60 * 60
    @database.setup!
    assert_equal [item], @database.list_video_materials
    assert_nil item.fetch("expires_at")
    assert_empty item.fetch("used_in_pages")
  end

  def test_rejects_missing_objects_and_external_paths_before_registering
    @s3.stub_responses(:head_object, "NotFound")
    assert_raises(ArgumentError) { @library.register(@payload) }
    assert_raises(ArgumentError) { @library.register(@payload.merge("avc" => "https://example.com/video.mp4")) }
    assert_empty @database.list_video_materials
  end

  def test_upgrades_an_existing_database_without_changing_pages
    page = @database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "既存の記事", body: "本文"))
    SQLite3::Database.new(@database.path.to_s) do |connection|
      connection.execute("DROP TABLE video_materials")
      connection.execute("PRAGMA user_version = 10")
    end
    @database.setup!
    assert_equal page, @database.find(page.id)
    item = @library.register(@payload)
    assert_equal [item], @database.list_video_materials
  end

  def test_registers_through_authenticated_api_and_lists_only_for_matching_inbox_filters
    codec = WeblogAuthoring::LambdaSession.new(secret: "s" * 64)
    token = codec.issue(kind: "session", attributes: { "github_user_id" => 630_181, "login" => "asonas", "csrf_token" => "csrf" }, ttl: 600)
    api = WeblogAuthoring::LambdaApi.new(database: @database, session_codec: codec, allowed_github_user_id: 630_181, s3_client: @s3, asset_bucket: "assets")
    event = { "requestContext" => { "http" => { "method" => "POST" } }, "rawPath" => "/api/uploads",
              "body" => JSON.generate(@payload.merge("action" => "register_video")), "headers" => {}, }
    assert_equal 401, api.call(event).fetch(:statusCode)
    event["cookies"] = ["weblog_authoring_session=#{token}"]
    assert_equal 403, api.call(event).fetch(:statusCode)
    event["headers"] = { "x-csrf-token" => "csrf", "content-type" => "application/json" }
    response = api.call(event)
    assert_equal 200, response.fetch(:statusCode), response.fetch(:body)
    registered = JSON.parse(response.fetch(:body)).fetch("item")
    event["rawPath"] = "/api/inbox"
    event["requestContext"]["http"]["method"] = "GET"
    [nil, "video", "photo"].each do |source|
      event["queryStringParameters"] = source ? { "source" => source } : {}
      response = api.call(event)
      assert_equal 200, response.fetch(:statusCode), response.fetch(:body)
      assert_equal(source == "photo" ? [] : [registered], JSON.parse(response.fetch(:body)).fetch("items"))
    end
  end
end
