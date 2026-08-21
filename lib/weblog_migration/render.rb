# frozen_string_literal: true

require "cgi"
require "date"
require "fileutils"
require "json"
require "kramdown"
require "kramdown-parser-gfm"
require "pathname"

module WeblogMigration
  module Render
    TEMPLATE = Pathname(__dir__).join("templates", "weblog.html")
    CARD_TEMPLATE = Pathname(__dir__).join("templates", "cards.html")
    CARD_SCRIPT = Pathname(__dir__).join("static", "cards.js")
    CARD_DATA_URL = "/static/cards-data.json"
    CARD_DEPTHS = [0, 1, 2, 3].freeze
    RANGE_DAYS = { "1d" => 1, "7d" => 7, "30d" => 30, "100d" => 100, "all" => nil }.freeze
    RANGE_LABELS = { "1d" => "1日", "7d" => "7日", "30d" => "30日", "100d" => "100日", "all" => "全期間" }.freeze

    module_function

    def render_site(normalized, index, output_dir, url_metadata_path: nil, asset_dir: nil)
      output_dir = Pathname(output_dir)
      FileUtils.mkdir_p(output_dir)
      public_posts = public_posts(normalized.posts)
      posts_by_id = public_posts.to_h { |post| [post.id, post] }
      assets = assets(public_posts)
      url_metadata = UrlMetadata.load_url_metadata(url_metadata_path)
      image_paths = copy_url_images(output_dir, asset_dir, url_metadata)
      write_card_script(output_dir)
      write_card_data(output_dir, normalized, url_metadata, image_paths)

      dated_posts = Hash.new { |hash, key| hash[key] = [] }
      undated_posts = []
      public_posts.each do |post|
        date_text = date_text(post)
        date_text.nil? ? undated_posts << post : dated_posts[date_text] << post
      end
      dated_posts.keys.sort.each do |date_value|
        write_page(
          output_dir.join(date_value, "index.html"),
          title: date_value,
          content: render_weblog(
            dated_posts.fetch(date_value),
            index,
            posts_by_id,
            assets,
            url_metadata,
            image_paths,
            show_link_groups: true
          )
        )
      end
      write_page(
        output_dir.join("undated", "index.html"),
        title: "日時なし",
        content: render_weblog(undated_posts, index, posts_by_id, assets, url_metadata, image_paths)
      )
      write_page(output_dir.join("index.html"), title: "log.ason.as", content: render_index(dated_posts, undated_posts))

      public_posts.each do |post|
        write_page(
          output_dir.join("posts", post.id, "index.html"),
          title: post.frontmatter.fetch("title").to_s,
          content: render_post_page(post, index, posts_by_id, assets, url_metadata, image_paths)
        )
        card_path = output_dir.join("posts", post.id, "cards", "index.html")
        FileUtils.mkdir_p(card_path.dirname)
        card_path.write(render_cards(normalized, index, root_id: post.id, url_metadata:, image_paths:), encoding: "UTF-8")
      end
      assets.sort.each do |asset_id, source_path|
        write_page(
          output_dir.join("assets", asset_id, "index.html"),
          title: source_path,
          content: render_asset_page(asset_id, source_path, index, posts_by_id)
        )
      end
    end

    def render_cards(normalized, index, root_id:, range_name: "all", depth: 1, url_metadata: nil, image_paths: nil)
      raise ArgumentError, "unknown range_name #{range_name.inspect}; expected one of #{RANGE_DAYS.keys.join(", ")}" unless RANGE_DAYS.key?(range_name)
      raise ArgumentError, "depth must be zero or greater" if depth.negative?

      public = public_posts(normalized.posts)
      posts_by_id = public.to_h { |post| [post.id, post] }
      asset_map = assets(public)
      url_metadata ||= {}
      image_paths ||= {}
      root = posts_by_id[root_id]
      raise ArgumentError, "root post is not public or does not exist: #{root_id}" if root.nil?

      start_date, end_date = range_bounds(root, RANGE_DAYS.fetch(range_name))
      neighbor_ids = index.neighbors(root_id, direction: "both", depth:, start_date:, end_date:)
      post_ids = neighbor_ids.select { |node_id| posts_by_id.key?(node_id) }.sort_by { |node_id| post_sort_key(posts_by_id.fetch(node_id)) }
      asset_ids = neighbor_ids.select { |node_id| asset_map.key?(node_id) }.sort_by { |node_id| asset_map.fetch(node_id) }
      cards = [render_exploration_post_card(root, root_id:, index:, expanded: true)]
      cards.concat(post_ids.map { |post_id| render_exploration_post_card(posts_by_id.fetch(post_id), root_id:, index:, expanded: false) })
      cards.concat(asset_ids.map do |asset_id|
        render_exploration_asset_card(asset_id, asset_map.fetch(asset_id), root_id:, index:, posts_by_id:, url_metadata:, image_paths:)
      end)
      controls = render_range_controls(range_name, root_id, depth)
      content = <<~HTML.chomp
        <section class="card-explorer" data-root-id="#{escape(root_id)}" data-range="#{escape(range_name)}" data-depth="#{depth}" data-card-data-url="#{CARD_DATA_URL}">#{controls}<div class="card-canvas">#{cards.join}</div><p class="card-status" role="status" aria-live="polite"></p><noscript><p>探索範囲とリンク深度の変更にはJavaScriptが必要です。</p></noscript></section>
      HTML
      render_card_document(title: "#{root.frontmatter.fetch("title")} — カード", content:)
    end

    def public_posts(posts)
      posts.select { |post| post.frontmatter["visibility"] == "public" }
    end

    def assets(posts)
      result = {}
      posts.each do |post|
        post.asset_references.each { |source_path| result[AssetManifest.stable_asset_id(source_path)] = source_path }
        post.external_urls.each { |url| result[AssetManifest.stable_url_asset_id(url)] = url }
      end
      result
    end

    def date_text(post)
      value = post.frontmatter["created_at"]
      value.nil? ? nil : value.to_s[0, 10]
    end

    def render_index(dated_posts, undated_posts)
      links = dated_posts.keys.sort.reverse.map do |date_value|
        "<li><a href=\"/#{escape(date_value)}/\">#{escape(date_value)}</a> (#{dated_posts.fetch(date_value).length}件)</li>"
      end
      links << "<li><a href=\"/undated/\">日時なし</a> (#{undated_posts.length}件)</li>" unless undated_posts.empty?
      links.empty? ? '<p class="empty-state">公開記事はありません。</p>' : "<ul class=\"date-list\">#{links.join}</ul>"
    end

    def render_weblog(posts, index, posts_by_id, asset_map, url_metadata, image_paths, show_link_groups: false)
      ordered = posts.sort_by { |post| post_sort_key(post) }
      return '<p class="empty-state">このページには公開記事がありません。</p>' if ordered.empty?

      cards = ordered.each_with_index.map do |post, position|
        render_post_card(post, index:, posts_by_id:, asset_map:, url_metadata:, image_paths:, expanded: position.zero?)
      end
      content = "<section class=\"post-stream\">#{cards.join}</section>"
      content += render_link_groups(ordered, posts_by_id, index, asset_map, url_metadata, image_paths) if show_link_groups
      content
    end

    def post_sort_key(post)
      [post.frontmatter["created_at"]&.to_s || "9999-99-99T99:99:99+00:00", post.frontmatter.fetch("title").to_s, post.id]
    end

    def render_post_page(post, index, posts_by_id, asset_map, url_metadata, image_paths)
      card = render_post_card(post, index:, posts_by_id:, asset_map:, url_metadata:, image_paths:, expanded: true)
      "<p class=\"post-mode-link\"><a href=\"/posts/#{escape(post.id)}/cards/\">カードモードで見る</a></p>#{card}#{render_post_backlinks(post.id, index, posts_by_id)}"
    end

    def render_range_controls(range_name, root_id, depth)
      options = RANGE_LABELS.map { |name, label| render_range_option(name, label, range_name, root_id, depth) }.join
      depth_options = CARD_DEPTHS.map { |value| render_depth_option(value, root_id, range_name, depth) }.join
      "<nav class=\"card-controls\" aria-label=\"カードの探索範囲\">#{options}<span class=\"depth-options\" aria-label=\"リンク深度\">#{depth_options}</span></nav>"
    end

    def render_range_option(name, label, selected_name, root_id, depth)
      selected = name == selected_name ? " is-selected" : ""
      current = name == selected_name ? ' aria-current="page"' : ""
      "<a class=\"range-option#{selected}\" data-range-option=\"#{escape(name)}\"#{current} href=\"?root=#{escape(root_id)}&amp;range=#{escape(name)}&amp;depth=#{depth}\">#{label}</a>"
    end

    def render_depth_option(value, root_id, range_name, selected_depth)
      selected = value == selected_depth ? " is-selected" : ""
      current = value == selected_depth ? ' aria-current="page"' : ""
      "<a class=\"depth-option#{selected}\" data-depth-option=\"#{value}\"#{current} href=\"?root=#{escape(root_id)}&amp;range=#{escape(range_name)}&amp;depth=#{value}\">深さ#{value}</a>"
    end

    def render_exploration_post_card(post, root_id:, index:, expanded:)
      is_root = post.id == root_id
      classes = ["exploration-card", "post-card", is_root ? "card--root" : "card--compact"]
      body_class = expanded ? "post-body" : "post-body post-body--compact"
      time_html = post.frontmatter["created_at"] ? "<time datetime=\"#{escape(post.frontmatter["created_at"])}\">#{escape(post.frontmatter["created_at"].to_s[0, 10])}</time>" : ""
      toggle = is_root ? "" : '<button type="button" data-card-toggle aria-expanded="false">展開</button>'
      relation = is_root ? "起点" : relation_label(root_id, post.id, index)
      "<article class=\"#{classes.join(" ")}\" data-post-id=\"#{escape(post.id)}\"><p class=\"card-relation\">#{escape(relation)}</p><header class=\"post-card__header\"><h2><a href=\"/posts/#{escape(post.id)}/\">#{escape(post.frontmatter.fetch("title"))}</a></h2>#{time_html}#{toggle}</header><div class=\"#{body_class}\">#{markdown_html(post.body)}</div></article>"
    end

    def render_exploration_asset_card(asset_id, source_path, root_id:, index:, posts_by_id:, url_metadata:, image_paths:)
      references = index.find_backlinks(asset_id).filter_map { |post_id| posts_by_id[post_id] }
      links = references.first(3).map { |post| "<li><a href=\"/posts/#{escape(post.id)}/\">#{escape(post.frontmatter.fetch("title"))}</a></li>" }
      remaining = references.length - [references.length, 3].min
      links << "<li>ほか#{remaining}件</li>" if remaining.positive?
      reference_html = links.empty? ? "<p>参照元なし</p>" : "<ul>#{links.join}</ul>"
      kind = source_path.start_with?("http://", "https://") ? AssetManifest.classify_url(source_path) : "asset"
      image_path = image_paths[asset_id]
      image_class = image_path ? " asset-card--with-image" : ""
      style = asset_background_style(image_path)
      "<article class=\"exploration-card asset-card#{image_class} card--compact\" #{style} data-asset-id=\"#{escape(asset_id)}\"><p class=\"card-relation\">#{escape(relation_label(root_id, asset_id, index))}</p><a href=\"/assets/#{escape(asset_id)}/\">#{asset_card_content(source_path, kind, url_metadata[asset_id])}</a><div class=\"asset-card__references\"><span>参照元</span>#{reference_html}</div></article>"
    end

    def relation_label(first_id, second_id, index)
      directions = index.directions_between(first_id, second_id)
      return "相互参照" if directions == %w[incoming outgoing]
      return "参照先" if directions.include?("outgoing")
      return "逆リンク" if directions.include?("incoming")

      "関連"
    end

    def render_card_document(title:, content:)
      CARD_TEMPLATE.read(encoding: "UTF-8").gsub("{{title}}", escape(title)).gsub("{{content}}", content)
    end

    def copy_url_images(output_dir, asset_dir, url_metadata)
      return {} if asset_dir.nil?

      asset_dir = Pathname(asset_dir)
      return {} unless asset_dir.directory?
      root = asset_dir.realpath
      image_paths = {}
      url_metadata.each do |asset_id, metadata|
        image = metadata["image"]
        local_path = image.is_a?(Hash) ? image["local_path"] : nil
        next unless local_path.is_a?(String) && local_path.match?(UrlMetadata::SAFE_FILENAME)
        source = asset_dir.join(local_path)
        next unless source.file? && source.realpath.dirname == root
        target = output_dir.join("assets", asset_id, local_path)
        FileUtils.mkdir_p(target.dirname)
        FileUtils.cp(source, target)
        image_paths[asset_id] = "/assets/#{asset_id}/#{local_path}"
      rescue Errno::ENOENT, Errno::EACCES
        next
      end
      image_paths
    end

    def write_card_script(output_dir)
      target = output_dir.join("static", "cards.js")
      FileUtils.mkdir_p(target.dirname)
      target.write(CARD_SCRIPT.read(encoding: "UTF-8"), encoding: "UTF-8")
    end

    def write_card_data(output_dir, normalized, url_metadata, image_paths)
      target = output_dir.join("static", "cards-data.json")
      data = card_data(normalized, url_metadata, image_paths)
      target.write(JSON.generate(deep_sort(data)) + "\n", encoding: "UTF-8")
    end

    def card_data(normalized, url_metadata, image_paths)
      public = public_posts(normalized.posts)
      posts_by_id = public.to_h { |post| [post.id, post] }
      asset_map = assets(public)
      edges = card_edges(normalized, public, posts_by_id, asset_map)
      posts = public.sort_by { |post| post_sort_key(post) }.map do |post|
        { "body_html" => markdown_html(post.body), "created_at" => post.frontmatter["created_at"], "id" => post.id, "title" => post.frontmatter.fetch("title").to_s }
      end
      assets_data = asset_map.sort_by { |_id, source_path| source_path }.map do |asset_id, source_path|
        metadata = url_metadata[asset_id]
        asset = {
          "id" => asset_id,
          "kind" => source_path.start_with?("http://", "https://") ? AssetManifest.classify_url(source_path) : "asset",
          "references" => edges.select { |_source, target| target == asset_id }.map(&:first),
          "source_path" => source_path
        }
        unless metadata.nil?
          asset["description"] = metadata["description"] if metadata.key?("description")
          asset["domain"] = metadata["domain"] if metadata.key?("domain")
          asset["title"] = metadata["title"] if metadata.key?("title")
        end
        asset["image_path"] = image_paths[asset_id] if image_paths.key?(asset_id)
        asset
      end
      { "assets" => assets_data, "edges" => edges.map { |source, target| { "source" => source, "target" => target } }, "posts" => posts, "version" => 1 }
    end

    def card_edges(normalized, public, posts_by_id, asset_map)
      edges = []
      public.each do |post|
        source_project = post.frontmatter.fetch("source_project").to_s
        post.links.each do |target_title|
          target_id = normalized.mapping["#{source_project}\0#{target_title}"]
          edges << [post.id, target_id] if target_id && posts_by_id.key?(target_id)
        end
        post.asset_references.each do |source_path|
          asset_id = AssetManifest.stable_asset_id(source_path)
          edges << [post.id, asset_id] if asset_map.key?(asset_id)
        end
        post.external_urls.each do |url|
          asset_id = AssetManifest.stable_url_asset_id(url)
          edges << [post.id, asset_id] if asset_map.key?(asset_id)
        end
      end
      edges.uniq.sort
    end

    def render_post_card(post, index:, posts_by_id:, asset_map:, url_metadata:, image_paths:, expanded:)
      created_at = post.frontmatter["created_at"]
      time_html = created_at ? "<time datetime=\"#{escape(created_at)}\">#{escape(created_at.to_s[0, 10])}</time>" : ""
      asset_ids = post.asset_references.map { |path| AssetManifest.stable_asset_id(path) } + post.external_urls.map { |url| AssetManifest.stable_url_asset_id(url) }
      asset_html = asset_ids.filter_map do |asset_id|
        next unless asset_map.key?(asset_id)
        render_asset_card(asset_id, asset_map.fetch(asset_id), index, posts_by_id, url_metadata[asset_id], image_paths[asset_id])
      end.join
      card_class = expanded ? "card--expanded" : "card--compact"
      body_class = expanded ? "post-body" : "post-body post-body--compact"
      "<article class=\"post-card #{card_class}\" data-post-id=\"#{escape(post.id)}\"><header class=\"post-card__header\"><h2><a href=\"/posts/#{escape(post.id)}/\">#{escape(post.frontmatter.fetch("title"))}</a></h2>#{time_html}</header><div class=\"#{body_class}\">#{markdown_html(post.body)}</div><div class=\"post-assets\">#{asset_html}</div></article>"
    end

    def render_asset_card(asset_id, source_path, index, posts_by_id, metadata, image_path)
      backlinks = index.find_backlinks(asset_id).filter_map { |post_id| posts_by_id[post_id] }
      used_by = if backlinks.empty?
                  ""
                else
                  links = backlinks.map { |post| "<a href=\"/posts/#{escape(post.id)}/\">#{escape(post.frontmatter.fetch("title"))}</a>" }.join
                  "<span class=\"asset-card__backlinks\">参照: #{links}</span>"
                end
      kind = source_path.start_with?("http://", "https://") ? AssetManifest.classify_url(source_path) : "asset"
      image_class = image_path ? " asset-card--with-image" : ""
      "<article class=\"asset-card#{image_class} card--compact\" #{asset_background_style(image_path)} data-asset-id=\"#{escape(asset_id)}\"><a href=\"/assets/#{escape(asset_id)}/\">#{asset_card_content(source_path, kind, metadata)}</a>#{used_by}</article>"
    end

    def asset_card_content(source_path, kind, metadata)
      title = metadata && metadata["title"].is_a?(String) && !metadata["title"].empty? ? metadata["title"] : nil
      domain = metadata && metadata["domain"].is_a?(String) && !metadata["domain"].empty? ? metadata["domain"] : nil
      description = metadata && metadata["description"].is_a?(String) && !metadata["description"].empty? ? metadata["description"] : nil
      name = title || domain || source_path
      domain_html = domain && domain != name ? "<span class=\"asset-card__domain\">#{escape(domain)}</span>" : ""
      url_html = metadata ? "<span class=\"asset-card__url\">#{escape(source_path)}</span>" : ""
      description_html = description ? "<span class=\"asset-card__description\">#{escape(description)}</span>" : ""
      "<span class=\"asset-card__kind\">#{escape(kind)}</span><span class=\"asset-card__name\">#{escape(name)}</span>#{domain_html}#{url_html}#{description_html}"
    end

    def asset_background_style(image_path)
      image_path ? "style=\"--asset-background-image: url('#{escape(image_path)}')\"" : ""
    end

    def render_post_backlinks(post_id, index, posts_by_id)
      backlinks = index.find_backlinks(post_id).filter_map { |source_id| posts_by_id[source_id] }
      return "" if backlinks.empty?
      links = backlinks.map { |post| "<li><a href=\"/posts/#{escape(post.id)}/\">#{escape(post.frontmatter.fetch("title"))}</a></li>" }.join
      "<aside class=\"backlinks\"><h2>参照している記事</h2><ul>#{links}</ul></aside>"
    end

    def render_link_groups(posts, posts_by_id, index, asset_map, url_metadata, image_paths)
      link_names = posts.flat_map(&:links).reject(&:empty?).uniq
      groups = link_names.filter_map do |link_name|
        linked_posts = posts_by_id.values.select { |post| post.links.include?(link_name) }
        next if linked_posts.empty?

        cards = linked_posts.sort_by { |post| post_sort_key(post) }.map do |post|
          render_post_card(
            post,
            index:,
            posts_by_id:,
            asset_map:,
            url_metadata:,
            image_paths:,
            expanded: false
          )
        end
        heading = posts_by_id.values.find { |post| post.frontmatter["source_title"] == link_name }
        label = if heading.nil?
                  escape(link_name)
                else
                  "<a href=\"/posts/#{escape(heading.id)}/\">#{escape(link_name)}</a>"
                end
        "<section class=\"link-group\" aria-labelledby=\"link-group-#{escape(link_name)}\"><h2 id=\"link-group-#{escape(link_name)}\">#{label}</h2><div class=\"post-stream\">#{cards.join}</div></section>"
      end
      groups.empty? ? "" : "<div class=\"link-groups\">#{groups.join}</div>"
    end

    def render_asset_page(asset_id, source_path, index, posts_by_id)
      "<article class=\"asset-page\" data-asset-id=\"#{escape(asset_id)}\"><p class=\"asset-page__placeholder\">#{escape(source_path)}</p></article>#{render_post_backlinks(asset_id, index, posts_by_id)}"
    end

    def range_bounds(root, days)
      return [nil, nil] if days.nil? || root.frontmatter["created_at"].nil?
      root_date = Date.iso8601(root.frontmatter.fetch("created_at").to_s[0, 10])
      [root_date - days, root_date + days]
    end

    def write_page(path, title:, content:)
      path = Pathname(path)
      FileUtils.mkdir_p(path.dirname)
      document = TEMPLATE.read(encoding: "UTF-8").gsub("{{title}}", escape(title)).gsub("{{content}}", content)
      path.write(document, encoding: "UTF-8")
    end

    def markdown_html(body)
      Kramdown::Document.new(body.to_s, input: "GFM", hard_wrap: true, parse_block_html: false, parse_span_html: false).to_html
    end

    def escape(value)
      CGI.escapeHTML(value.to_s)
    end

    def deep_sort(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, result| result[key] = deep_sort(value[key]) }
      when Array
        value.map { |item| deep_sort(item) }
      else
        value
      end
    end
  end
end
