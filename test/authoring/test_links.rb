# frozen_string_literal: true

require_relative "../test_helper"

class TestLinks < Minitest::Test
  def test_extract_wiki_links_trims_names_and_ignores_code_fences
    body = "[[ page-a ]]\n\n```md\n[[ignored]]\n```\n\n[[page-b]]"

    links = WeblogAuthoring.extract_wiki_links(body)

    assert_equal %w[page-a page-b], links.map(&:name)
  end

  def test_replace_wiki_links_does_not_replace_prefix_matches
    result = WeblogAuthoring.replace_wiki_links("[[page-a]] [[page-ab]]", old_name: "page-a", new_name: "page-b")

    assert_equal "[[page-b]] [[page-ab]]", result
  end

  def test_shorter_fence_does_not_close_longer_fence
    body = "````md\n```\n[[ignored]]\n```\n````\n[[kept]]"

    assert_equal ["kept"], WeblogAuthoring.extract_wiki_links(body).map(&:name)
  end

  def test_extract_wiki_links_keeps_unsaved_link_names
    body = "[[ draft page ]]\n[[another]]\n"

    assert_equal ["draft page", "another"], WeblogAuthoring.extract_wiki_links(body).map(&:name)
  end
end
