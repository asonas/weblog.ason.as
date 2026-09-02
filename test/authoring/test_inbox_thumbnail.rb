# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/image_inbox"
require_relative "../../lib/weblog_authoring/inbox_thumbnail"

class InboxThumbnailTest < Minitest::Test
  SourceObject = Data.define(:body)

  class FakeImage
    attr_reader :writes

    def initialize
      @writes = []
    end

    def write_to_buffer(format, **options)
      writes << [format, options]
      "thumbnail-data"
    end
  end

  class FakeImageClass
    attr_reader :requests

    def initialize(image)
      @image = image
      @requests = []
    end

    def thumbnail_buffer(source, width, **options)
      requests << [source, width, options]
      @image
    end
  end

  class FakeS3
    attr_reader :gets, :puts

    def initialize
      @puts = []
      @gets = []
    end

    def get_object(bucket:, key:)
      gets << { bucket:, key: }
      SourceObject.new(StringIO.new("original-data"))
    end

    def put_object(**attributes)
      puts << attributes
    end
  end

  def test_creates_a_bounded_webp_thumbnail_beside_the_inbox_images
    image = FakeImage.new
    image_class = FakeImageClass.new(image)
    s3 = FakeS3.new
    thumbnail = WeblogAuthoring::InboxThumbnail.new(
      s3_client: s3, bucket: "assets", image_class:
    )
    source_key = "assets/inbox/2026/09/02/11111111222233334444555555555555.jpg"

    key = thumbnail.create(key: source_key)

    assert_equal "assets/inbox/thumbnails/2026/09/02/11111111222233334444555555555555.webp", key
    assert_equal [["original-data", 512, { height: 512, size: :down }]], image_class.requests
    assert_equal [[".webp", { Q: 75, strip: true }]], image.writes
    assert_equal [{ bucket: "assets", key: source_key }], s3.gets
    assert_equal({
      bucket: "assets",
      key:,
      body: "thumbnail-data",
      content_type: "image/webp",
      cache_control: "private, max-age=604800",
    }, s3.puts.fetch(0))
  end
end
