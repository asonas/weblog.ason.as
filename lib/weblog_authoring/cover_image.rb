# frozen_string_literal: true

require_relative "markdown_parser"

module WeblogAuthoring
  module CoverImage
    MODES = %w[auto explicit none].freeze
    LOCAL_IMAGE = %r{\A/assets/[^\s]+\z}
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

      document = Kramdown::Document.new(page.body.to_s, input: "WeblogGFM")
      legacy_urls = page.body.to_s.scan(LEGACY_IMAGE).flatten
      find_visible_image(document.root, asset_image_paths.slice(*legacy_urls))
    end

    def find_visible_image(node, asset_image_paths)
      return nil if %i[spoiler spoiler_block codespan codeblock].include?(node.type)
      return node.attr["src"].gsub(/\\([[:punct:]])/, '\1') if node.type == :img && local?(node.attr["src"])
      path = asset_image_paths[node.attr["href"]] if node.type == :a
      if path
        return "/assets/#{path}"
      end
      if node.type == :text
        node.value.to_s.scan(LEGACY_IMAGE).each do |url|
          path = asset_image_paths[url.first]
          return "/assets/#{path}" if path
        end
      end
      node.children.each do |child|
        image = find_visible_image(child, asset_image_paths)
        return image if image
      end
      nil
    end

    def local?(url)
      LOCAL_IMAGE.match?(url.to_s)
    end
  end
end
