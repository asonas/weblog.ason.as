# frozen_string_literal: true

require_relative "../test_helper"

class TestNames < Minitest::Test
  def test_invalid_page_names_are_rejected
    ["", ".", "..", "a/../b", "assets/file", "api/routes", "a?b", "a#b", "a<b", "a>b", "a\\b", "a\nb", "a\x00b", "manage", "api"].each do |name|
      assert_raises(ArgumentError) { WeblogAuthoring.validate_page_name(name) }
    end
  end

  def test_page_names_are_trimmed_but_case_sensitive
    assert_equal "KORG multi/poly", WeblogAuthoring.validate_page_name("KORG multi/poly")
    assert_equal "KORG%20multi%2Fpoly", WeblogAuthoring.encoded_route("KORG multi/poly")
    assert_equal "page-a", WeblogAuthoring.validate_page_name(" page-a ")
    assert_equal "Page-A", WeblogAuthoring.validate_page_name("Page-A")
    assert_equal "日本語 page", WeblogAuthoring.validate_page_name(" 日本語 page ")
    assert_equal "2026-01-01", WeblogAuthoring.validate_page_name("2026-01-01")
  end

  def test_named_page_path_is_url_encoded_and_date_path_is_fixed
    root = Pathname("/tmp/content")

    assert_equal "page-a", WeblogAuthoring.encoded_page_name("page-a")
    assert_equal "%50age-%41", WeblogAuthoring.encoded_page_name("Page-A")
    assert_equal "%E6%97%A5%E6%9C%AC%E8%AA%9E%20page", WeblogAuthoring.encoded_page_name("日本語 page")
    assert_equal "page-a", WeblogAuthoring.encoded_route("page-a")
    assert_equal "Page-A", WeblogAuthoring.encoded_route("Page-A")
    assert_equal "2026-01-01", WeblogAuthoring.encoded_route("2026-01-01")
    assert_equal root.join("page-a.md"), WeblogAuthoring.page_path(root, "named", name: "page-a", page_date: nil)
    assert_equal root.join("%50age-%41.md"), WeblogAuthoring.page_path(root, "named", name: "Page-A", page_date: nil)
    assert_equal root.join("2026-01-01.md"), WeblogAuthoring.page_path(root, "date", name: nil, page_date: Date.new(2026, 1, 1))
  end

  def test_page_name_rejects_syntax_delimiters
    ["[[page-a]]", "---"].each do |name|
      assert_raises(ArgumentError) { WeblogAuthoring.validate_page_name(name) }
    end
  end

  def test_public_url_preserves_ascii_case_and_encodes_japanese_spaces_and_literal_percent_once
    assert_equal "%E3%80%8CWhere%20the%20tracks%20go%20next%E3%80%8D%E3%82%92%E7%8F%BE%E5%9C%B0%E3%81%A7%E8%A6%8B%E3%81%9F%E3%80%82", WeblogAuthoring.encoded_route("「Where the tracks go next」を現地で見た。")
    assert_equal "literal%2557", WeblogAuthoring.encoded_route("literal%57")
    assert_equal "%57here", WeblogAuthoring.encoded_page_name("Where")
  end

  def test_page_name_allows_normal_punctuation
    assert_equal "status: draft", WeblogAuthoring.validate_page_name("status: draft")
  end

  def test_date_page_path_rejects_non_date_values
    assert_raises(ArgumentError) do
      WeblogAuthoring.page_path("/tmp/content", "date", name: nil, page_date: Time.utc(2026, 1, 1))
    end
  end
end
