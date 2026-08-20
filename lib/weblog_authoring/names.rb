# frozen_string_literal: true

require "date"
require "pathname"

module WeblogAuthoring
  DATE_NAME = /\A\d{4}-\d{2}-\d{2}\z/.freeze
  RESERVED_ROUTES = %w[manage api static].freeze
  UNRESERVED_FILENAME_BYTE = /[a-z0-9\-._~]/.freeze

  module_function

  def validate_page_name(name)
    raise ArgumentError, "page name must be a string" unless name.is_a?(String)

    normalized = name.strip
    raise ArgumentError, "page name must not be empty" if normalized.empty?
    raise ArgumentError, "page name contains a forbidden character" if normalized.match?(/[\/?#\r\n]/)
    raise ArgumentError, "page name contains a control character" if normalized.each_codepoint.any? { |codepoint| codepoint < 32 || codepoint == 127 }
    raise ArgumentError, "date-shaped names are reserved" if DATE_NAME.match?(normalized)
    raise ArgumentError, "page name collides with a reserved route" if RESERVED_ROUTES.include?(normalized)
    if normalized.include?("[[") || normalized.include?("]]") || normalized.start_with?("---")
      raise ArgumentError, "page name collides with document syntax"
    end

    normalized
  end

  def encoded_page_name(name)
    validate_page_name(name).bytes.map { |byte| encode_byte(byte) }.join
  end

  def page_path(content_dir, page_type, name:, page_date:)
    root = Pathname(content_dir)

    case page_type
    when "named"
      raise ArgumentError, "named pages require a name" if name.nil?

      root.join("#{encoded_page_name(name)}.md")
    when "date"
      raise ArgumentError, "date pages require a date" unless page_date.instance_of?(Date)

      root.join("#{page_date.iso8601}.md")
    else
      raise ArgumentError, "unknown page type: #{page_type}"
    end
  end

  def encode_byte(byte)
    character = byte.chr
    # Keep named-page filenames distinct on case-insensitive filesystems.
    return character if character.match?(UNRESERVED_FILENAME_BYTE)

    format("%%%02X", byte)
  end
  private_class_method :encode_byte
end
