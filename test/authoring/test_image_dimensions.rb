# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "vips"
require "weblog_authoring/development_database"
require "weblog_authoring/image_dimensions"
require "weblog_authoring/image_upload"

class ImageDimensionsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "database.sqlite3")
    @database = WeblogAuthoring::DevelopmentDatabase.new(@path, content_dir: @directory)
    @database.setup!
    @s3 = Aws::S3::Client.new(region: "ap-northeast-1", stub_responses: true)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_client_dimensions_are_persisted_without_reading_the_image
    upload = WeblogAuthoring::ImageUpload.new(database: @database, s3_client: @s3, bucket: "site")
    result = upload.create(content_type: "image/webp", size: 1000, width: 800, height: 1200)
    reopened = WeblogAuthoring::DevelopmentDatabase.new(@path, content_dir: @directory)
    assert_equal [800, 1200], reopened.find_image_dimensions(result.fetch("public_url"))
    assert_empty @s3.api_requests
    assert_raises(ArgumentError) { upload.create(content_type: "image/webp", size: 1000, width: -1, height: 1200) }
  end

  def test_backfill_reads_each_unregistered_image_only_once
    @s3.stub_responses(:get_object, body: Vips::Image.black(32, 48, bands: 3).write_to_buffer(".png"))
    images = WeblogAuthoring::ImageDimensions.new(database: @database, s3_client: @s3, bucket: "site")
    2.times { assert_equal [32, 48], images.backfill("/assets/portrait.png") }
    assert_equal 1, @s3.api_requests.length
    assert_equal [32, 48], @database.find_image_dimensions("/assets/portrait.png")
  end

  def test_upgrades_version_eleven_without_replacing_existing_data
    sqlite = SQLite3::Database.new(@path)
    sqlite.execute("DROP TABLE image_dimensions")
    sqlite.execute("PRAGMA user_version = 11")
    sqlite.close
    @database.setup!
    @database.save_image_dimensions("/assets/photo.webp", width: 48, height: 32)
    @database.setup!
    assert_equal [48, 32], @database.find_image_dimensions("/assets/photo.webp")
    assert_equal [], @database.list_pages
  end
end
