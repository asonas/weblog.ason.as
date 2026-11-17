# frozen_string_literal: true

require_relative "../test_helper"
require "aws-sdk-s3"
require "weblog_authoring/models"
require "weblog_authoring/og_image"

class OgImageTest < Minitest::Test
  Layout = WeblogAuthoring::OgImage::Layout

  # A stand-in for drawing text: full-width characters are one em wide and the rest 0.6 em.
  MEASURE = ->(text, size) { text.each_char.sum { |char| char.ascii_only? ? size * 0.6 : size } }

  def layout(title) = Layout.new(measure: MEASURE).call(title)

  def test_breaks_between_a_latin_word_and_the_katakana_that_follows
    assert_equal %w[Webmention クラブ], layout("Webmentionクラブ").lines
  end

  def test_keeps_a_particle_on_the_line_of_the_word_it_follows
    lines = layout("ason.asにあった記事をweblog.ason.asに移行しました。").lines

    assert_equal "ason.asにあった記事をweblog.ason.asに移行しました。", lines.join
    assert_includes lines, "weblog.ason.asに"
    lines.each { |line| refute_match(/\A[にをはがのでと]/, line) }
  end

  def test_every_line_fits_the_box_even_when_one_word_is_longer_than_a_line
    result = layout("https://example.com/#{'very-long-path-segment/' * 8}の話")

    result.lines.each { |line| assert_operator MEASURE.call(line, result.size), :<=, Layout::BOX_WIDTH, line }
    assert_operator result.lines.length * result.size * Layout::LINE_HEIGHT, :<=, Layout::BOX_HEIGHT
  end

  def test_a_title_too_long_for_the_smallest_size_is_cut_with_an_ellipsis
    result = layout("とても長いタイトルを付けた記事について、" * 20)

    assert_equal Layout::SIZES.last, result.size
    assert_operator result.lines.length * result.size * Layout::LINE_HEIGHT, :<=, Layout::BOX_HEIGHT
    assert result.lines.last.end_with?(Layout::ELLIPSIS)
    result.lines.each { |line| assert_operator MEASURE.call(line, result.size), :<=, Layout::BOX_WIDTH, line }
  end

  def test_emoji_and_control_characters_are_left_out_because_they_cannot_be_drawn
    assert_equal "絵文字と記号★を含む", layout("絵文字🎹と記号★を\u0000含む").lines.join
    assert_empty layout("🎹👨‍👩‍👧").lines
  end

  # Candidate lines are sized by adding up unit widths. A line drawn whole can be wider than that sum,
  # and a layout that then overflows must be given up for a narrower one or a smaller size.
  def test_a_line_wider_than_the_sum_of_its_units_is_never_accepted
    wider_when_whole = ->(text, size) { MEASURE.call(text, size) * (text.length > 6 ? 1.12 : 1.0) }
    result = Layout.new(measure: wider_when_whole).call("公開した記事の一覧と下書きの一覧を同じ画面にまとめた話")

    result.lines.each { |line| assert_operator wider_when_whole.call(line, result.size), :<=, Layout::BOX_WIDTH, line }
    assert_equal "公開した記事の一覧と下書きの一覧を同じ画面にまとめた話", result.lines.join
  end

  # The public page builds this key from the title alone, so a renamed article must get a new URL
  # instead of the image cached for a year under the old one.
  def test_key_follows_the_title
    key = WeblogAuthoring::OgImage.key("記事")

    assert_match(%r{\Aassets/og/[0-9a-f]{32}\.png\z}, key)
    assert_equal key, WeblogAuthoring::OgImage.key("記事")
    refute_equal key, WeblogAuthoring::OgImage.key("記事2")
  end

  def test_renders_a_png_of_the_open_graph_size
    require "vips"
    renderer = WeblogAuthoring::OgImage::Renderer.new

    [renderer.article("ason.asにあった記事をweblog.ason.asに移行しました。"), renderer.home].each do |png|
      image = Vips::Image.new_from_buffer(png, "")
      assert_equal [1200, 630], [image.width, image.height]
    end
  end

  def test_store_writes_only_the_missing_image_of_an_article_without_a_cover
    objects = {}
    s3 = Aws::S3::Client.new(stub_responses: true)
    s3.stub_responses(:head_object, ->(context) { objects.key?(context.params[:key]) ? {} : "Forbidden" })
    s3.stub_responses(:put_object, lambda { |context|
      objects[context.params[:key]] = context.params
      {}
    })
    renderer = Struct.new(:titles) do
      def article(title) = (titles << title) && "png"
    end.new([])
    store = WeblogAuthoring::OgImage::Store.new(s3_client: s3, bucket: "site", renderer:)

    2.times { assert_equal WeblogAuthoring::OgImage.key("記事"), store.ensure(page(name: "記事", body: "本文")) }
    assert_nil store.ensure(page(name: "写真", body: "![写真](/assets/photo.webp)"))

    assert_equal ["記事"], renderer.titles
    written = objects.fetch(WeblogAuthoring::OgImage.key("記事"))
    assert_equal ["image/png", "public, max-age=31536000, immutable"], written.values_at(:content_type, :cache_control)
    assert_equal 1, objects.length
  end

  def test_store_skips_the_image_once_the_publication_has_spent_its_time_on_images
    now = 100.0
    s3 = Aws::S3::Client.new(stub_responses: true)
    s3.stub_responses(:head_object, "Forbidden")
    renderer = Object.new
    def renderer.article(_title) = "png"
    store = WeblogAuthoring::OgImage::Store.new(s3_client: s3, bucket: "site", renderer:, clock: -> { now })
    deadline = store.deadline(20)

    now = 119.0
    refute_nil store.ensure(page(name: "間に合う記事", body: "本文"), deadline:)
    now = 121.0
    assert_nil store.ensure(page(name: "間に合わない記事", body: "本文"), deadline:)

    assert_equal 1, (s3.api_requests.count { |request| request[:operation_name] == :put_object })
  end

  # Publication calls this after placing the article's HTML. An image that cannot be made must not fail the publication.
  def test_store_reports_a_failure_without_raising
    s3 = Aws::S3::Client.new(stub_responses: true)
    s3.stub_responses(:head_object, "Forbidden")
    renderer = Object.new
    def renderer.article(_title) = raise(LoadError, "cannot load such file -- vips")
    store = WeblogAuthoring::OgImage::Store.new(s3_client: s3, bucket: "site", renderer:)

    _out, err = capture_io { assert_nil store.ensure(page(name: "記事", body: "本文")) }

    assert_includes err, "Could not create the Open Graph image"
    assert_equal 0, (s3.api_requests.count { |request| request[:operation_name] == :put_object })
  end

  private

  def page(name:, body:)
    now = Time.iso8601("2026-11-17T00:00:00Z")
    WeblogAuthoring::ArticleDocument.new(
      id: name, page_type: "named", name:, title: nil, status: "published", created_at: now, updated_at: now, published_at: now,
      path: Pathname("content/pages/#{name}.md"), body:, links: []
    )
  end
end
