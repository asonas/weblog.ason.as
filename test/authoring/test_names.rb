# frozen_string_literal: true

require_relative "../test_helper"

class TestNames < Minitest::Test
  def test_invalid_page_names_are_rejected
    ["", "2026-01-01", "a/b", "a?b", "a#b", "a\nb", "a\x00b", "manage", "api"].each do |name|
      assert_raises(ArgumentError) { WeblogAuthoring.validate_page_name(name) }
    end
  end

  def test_page_names_are_trimmed_but_case_sensitive
    assert_equal "page-a", WeblogAuthoring.validate_page_name(" page-a ")
    assert_equal "Page-A", WeblogAuthoring.validate_page_name("Page-A")
    assert_equal "日本語 page", WeblogAuthoring.validate_page_name(" 日本語 page ")
  end

  def test_named_page_path_is_url_encoded_and_date_path_is_fixed
    root = Pathname("/tmp/content")

    assert_equal "page-a", WeblogAuthoring.encoded_page_name("page-a")
    assert_equal "%E6%97%A5%E6%9C%AC%E8%AA%9E%20page", WeblogAuthoring.encoded_page_name("日本語 page")
    assert_equal root.join("page-a.md"), WeblogAuthoring.page_path(root, "named", name: "page-a", page_date: nil)
    assert_equal root.join("2026-01-01.md"), WeblogAuthoring.page_path(root, "date", name: nil, page_date: Date.new(2026, 1, 1))
  end

  def test_page_name_rejects_syntax_delimiters
    ["[[page-a]]", "---", "status: draft"].each do |name|
      assert_raises(ArgumentError) { WeblogAuthoring.validate_page_name(name) }
    end
  end

  def test_date_page_path_rejects_non_date_values
    assert_raises(ArgumentError) do
      WeblogAuthoring.page_path("/tmp/content", "date", name: nil, page_date: Time.utc(2026, 1, 1))
    end
  end
end
