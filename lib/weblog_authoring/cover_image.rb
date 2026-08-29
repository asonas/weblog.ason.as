# frozen_string_literal: true

module WeblogAuthoring
  module CoverImage
    MODES = %w[auto explicit none].freeze
    LOCAL_IMAGE = %r{\A/assets/[^\s]+\z}
    MARKDOWN_IMAGE = /!\[[^\]]*\]\((\/assets\/[^\s)]+)(?:\s+[^)]*)?\)/
    LEGACY_IMAGE = /\[(https?:\/\/[^\]\s]+)(?:\s+[^\]]+)?\]/

    module_function

    def validate(mode, image_url)
      resolved_mode = mode || "auto"
      raise ArgumentError, "cover_mode is invalid" unless MODES.include?(resolved_mode)
      if resolved_mode == "explicit"
        raise ArgumentError, "cover_image_url must be a local asset" unless local?(image_url)
      elsif !image_url.nil?
        raise ArgumentError, "cover_image_url is only allowed for explicit mode"
      end
      [resolved_mode, image_url]
    end

    def resolve(page, asset_image_paths: {})
      return nil if page.cover_mode == "none"
      return page.cover_image_url if page.cover_mode == "explicit" && local?(page.cover_image_url)

      candidates = []
      page.body.to_s.to_enum(:scan, MARKDOWN_IMAGE).each do
        match = Regexp.last_match
        candidates << [match.begin(0), match[1]]
      end
      page.body.to_s.to_enum(:scan, LEGACY_IMAGE).each do
        match = Regexp.last_match
        local_path = asset_image_paths[match[1]]
        candidates << [match.begin(0), "/assets/#{local_path}"] if local_path
      end
      candidates.min_by(&:first)&.last
    end

    def local?(url)
      LOCAL_IMAGE.match?(url.to_s)
    end
  end
end
