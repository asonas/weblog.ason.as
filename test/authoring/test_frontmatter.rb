# frozen_string_literal: true

require_relative "../test_helper"

class TestFrontmatter < Minitest::Test
  def test_date_document_round_trips_frontmatter_and_body
    path = Pathname("/tmp/content/2026-01-01.md")
    document = WeblogAuthoring::PageDocument.new(
      id: "page-id",
      page_type: "date",
      name: nil,
      page_date: Date.new(2026, 1, 1),
      title: "A day",
      status: "draft",
      created_at: Time.iso8601("2026-01-01T00:00:00Z"),
      updated_at: Time.iso8601("2026-01-02T00:00:00Z"),
      published_at: nil,
      path:,
      body: "本文\n"
    )

    parsed = WeblogAuthoring.parse_document(path, WeblogAuthoring.serialize_document(document))

    assert_equal document, parsed
  end

  def test_named_document_uses_name_as_display_title
    document = WeblogAuthoring::PageDocument.new(
      id: "page-id",
      page_type: "named",
      name: "page-a",
      page_date: nil,
      title: nil,
      status: "published",
      created_at: Time.iso8601("2026-01-01T00:00:00Z"),
      updated_at: Time.iso8601("2026-01-01T00:00:00Z"),
      published_at: Time.iso8601("2026-01-01T00:00:00Z"),
      path: Pathname("/tmp/content/page-a.md"),
      body: ""
    )

    assert_equal "page-a", document.display_title
  end

  def test_invalid_status_returns_page_problem
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      <<~DOC
        ---
        id: page-id
        page_type: named
        name: page-a
        status: broken
        created_at: 2026-01-01 00:00:00 Z
        updated_at: 2026-01-01 00:00:00 Z
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "status"
  end

  def test_non_string_id_returns_page_problem
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      <<~DOC
        ---
        id: 123
        page_type: named
        name: page-a
        status: draft
        created_at: 2026-01-01 00:00:00 Z
        updated_at: 2026-01-01 00:00:00 Z
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "id"
  end

  def test_missing_id_returns_page_problem
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      <<~DOC
        ---
        page_type: named
        name: page-a
        status: draft
        created_at: 2026-01-01 00:00:00 Z
        updated_at: 2026-01-01 00:00:00 Z
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "id"
  end

  def test_created_at_must_be_a_datetime
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      <<~DOC
        ---
        id: page-id
        page_type: named
        name: page-a
        status: draft
        created_at: not-a-time
        updated_at: 2026-01-01 00:00:00 Z
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "created_at"
  end

  def test_updated_at_must_be_a_datetime
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      <<~DOC
        ---
        id: page-id
        page_type: named
        name: page-a
        status: draft
        created_at: 2026-01-01 00:00:00 Z
        updated_at: 2026-01-01
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "updated_at"
  end

  def test_unknown_key_returns_page_problem
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      <<~DOC
        ---
        id: page-id
        page_type: named
        name: page-a
        status: draft
        created_at: 2026-01-01 00:00:00 Z
        updated_at: 2026-01-01 00:00:00 Z
        extra: true
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "unknown key"
  end

  def test_broken_yaml_returns_page_problem
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      "---\nid: [\n---\nbody\n"
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "invalid"
  end

  def test_date_document_rejects_datetime_page_date
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/2026-01-01.md"),
      <<~DOC
        ---
        id: page-id
        page_type: date
        page_date: 2026-01-01 00:00:00 Z
        status: draft
        created_at: 2026-01-01 00:00:00 Z
        updated_at: 2026-01-01 00:00:00 Z
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "page_date"
  end

  def test_published_at_must_be_a_datetime
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      <<~DOC
        ---
        id: page-id
        page_type: named
        name: page-a
        status: published
        created_at: 2026-01-01 00:00:00 Z
        updated_at: 2026-01-01 00:00:00 Z
        published_at: 2026-01-01
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "published_at"
  end

  def test_safe_load_rejects_arbitrary_classes
    result = WeblogAuthoring.parse_document(
      Pathname("/tmp/content/page-a.md"),
      <<~DOC
        ---
        id: !ruby/object:Object {}
        page_type: named
        name: page-a
        status: draft
        created_at: 2026-01-01 00:00:00 Z
        updated_at: 2026-01-01 00:00:00 Z
        ---
        body
      DOC
    )

    assert_instance_of WeblogAuthoring::PageProblem, result
    assert_includes result.detail, "invalid"
  end
end
