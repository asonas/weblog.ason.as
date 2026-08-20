# frozen_string_literal: true

require "date"
require "pathname"
require "psych"

module WeblogAuthoring
  REQUIRED_KEYS = %w[id page_type status created_at updated_at].freeze
  ALLOWED_KEYS = (REQUIRED_KEYS + %w[name page_date title published_at]).freeze

  module_function

  def parse_document(path, text)
    path = Pathname(path)
    return problem(path, "frontmatter is missing") unless text.start_with?("---\n")

    marker = text.index("\n---\n", 4)
    return problem(path, "frontmatter is not closed") if marker.nil?

    values = load_frontmatter(path, text[4...marker])
    return values if values.is_a?(PageProblem)
    return problem(path, "frontmatter must be a mapping") unless values.is_a?(Hash)

    unknown_keys = values.keys - ALLOWED_KEYS
    return problem(path, "unknown key: #{unknown_keys.sort.first}") unless unknown_keys.empty?

    missing_keys = REQUIRED_KEYS - values.keys
    return problem(path, "missing required key: #{missing_keys.sort.first}") unless missing_keys.empty?

    return problem(path, "id must be a non-empty string") unless values["id"].is_a?(String) && !values["id"].empty?
    return problem(path, "page_type must be date or named") unless %w[date named].include?(values["page_type"])
    return problem(path, "status must be draft or published") unless %w[draft published].include?(values["status"])
    return problem(path, "created_at and updated_at must be datetimes") unless time_value?(values["created_at"]) && time_value?(values["updated_at"])

    page_date = values["page_date"]
    return problem(path, "page_date must be a date") unless page_date.nil? || page_date.instance_of?(Date)

    published_at = values["published_at"]
    return problem(path, "published_at must be a datetime") unless published_at.nil? || time_value?(published_at)

    name = values["name"]
    return problem(path, "name must be a string") unless name.nil? || name.is_a?(String)

    title = values["title"]
    return problem(path, "title must be a string") unless title.nil? || title.is_a?(String)

    if values["page_type"] == "date" && page_date.nil?
      return problem(path, "date pages require page_date")
    end
    if values["page_type"] == "named" && (name.nil? || name.empty?)
      return problem(path, "named pages require name")
    end

    PageDocument.new(
      id: values["id"],
      page_type: values["page_type"],
      name:,
      page_date:,
      title:,
      status: values["status"],
      created_at: values["created_at"],
      updated_at: values["updated_at"],
      published_at:,
      path:,
      body: text[(marker + "\n---\n".length)..] || "",
      links: []
    )
  end

  def serialize_document(document)
    values = {
      "id" => document.id,
      "page_type" => document.page_type,
      "name" => document.name,
      "page_date" => document.page_date,
      "title" => document.title,
      "status" => document.status,
      "created_at" => document.created_at&.dup,
      "updated_at" => document.updated_at&.dup,
      "published_at" => document.published_at&.dup
    }
    serialized = Psych.safe_dump(values, permitted_classes: [Date, Time], line_width: -1).delete_prefix("---\n")

    +"---\n#{serialized}---\n#{document.body}"
  end

  def load_frontmatter(path, text)
    Psych.safe_load(text, permitted_classes: [Date, Time], aliases: false)
  rescue Psych::Exception => error
    problem(path, "frontmatter is invalid: #{error.message}")
  end
  private_class_method :load_frontmatter

  def problem(path, detail)
    PageProblem.new(path:, detail:)
  end
  private_class_method :problem

  def time_value?(value)
    value.is_a?(Time)
  end
  private_class_method :time_value?
end
