# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "open3"

class PublicFormatFunctionTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # この関数の出力がCloudFrontのキャッシュキーになる。htmlとmarkdown以外の値や、閲覧者が送った値が残ると、キーが増えるか別形式の応答が混ざる
  def test_cache_key_format_has_two_values_and_ignores_the_viewer_supplied_header
    output, status = Open3.capture2("node", File.join(__dir__, "public_format_cases.js"), File.join(ROOT, "infra/production/public_format.js"))
    assert status.success?

    assert_equal({
      "missing" => "html", "browser" => "html", "markdown" => "markdown", "weighted" => "markdown",
      "refused" => "html", "lookalike" => "html", "multiValue" => "markdown",
      "feed" => "html", "sitemap" => "html", "disabled" => "html",
    }, JSON.parse(output))
  end
end
