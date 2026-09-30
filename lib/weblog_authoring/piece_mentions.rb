# frozen_string_literal: true

require_relative "links"
require_relative "markdown"

module WeblogAuthoring
  module PieceMentions
    def self.schema(prefix)
      "CREATE TABLE IF NOT EXISTS #{prefix}article_piece_links (version_id TEXT NOT NULL, article_id TEXT NOT NULL, piece_id TEXT NOT NULL, target_name TEXT NOT NULL, day TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (version_id, piece_id, target_name))"
    end

    def self.names(body)
      names = []
      visit = lambda do |node|
        if node.type == :text
          names.concat(node.value.scan(WeblogAuthoring::LINK_PATTERN).flatten.map(&:strip))
        elsif !%i[codeblock codespan a img html_element].include?(node.type)
          node.children.each { |child| visit.call(child) }
        end
      end
      visit.call(Kramdown::Document.new(body, input: "WeblogGFM").root)
      names.reject(&:empty?).uniq
    end

    def mentioned_by_days(route, before: nil)
      WeblogAuthoring.validate_page_name(route)
      raise DraftStore::Error, "Invalid day cursor" if before && !/\A\d{4}-\d{2}-\d{2}\z/.match?(before)
      @connect.call do |db|
        db.transaction do
          owner = db.query("SELECT article_id FROM #{db.prefix}article_publication_routes WHERE route = $1", [route]).first
          owner_id = owner && owner.fetch("article_id")
          names = owner_id ? db.query("SELECT route FROM #{db.prefix}article_publication_routes WHERE article_id = $1", [owner_id]).map { |row| row.fetch("route") } : [route]
          parameters = names + [owner_id || "", before || "9999-12-31"]
          targets = names.each_index.map { |index| "$#{index + 1}" }.join(", ")
          source = "FROM #{db.prefix}article_piece_links l JOIN #{db.prefix}article_publication_heads h ON h.article_id = l.article_id AND h.active_id = l.version_id"
          condition = "l.target_name IN (#{targets}) AND l.article_id <> $#{names.length + 1} AND l.day < $#{names.length + 2}"
          dates = db.query("SELECT DISTINCT l.day #{source} WHERE #{condition} ORDER BY l.day DESC LIMIT 11", parameters).map { |row| row.fetch("day") }
          days = dates.first(10).map do |day|
            rows = db.query("SELECT DISTINCT l.piece_id, l.position, v.route, v.metadata #{source} JOIN #{db.prefix}article_published_versions v ON v.id = l.version_id WHERE #{condition} AND l.day = $#{parameters.length + 1} ORDER BY l.position", parameters + [day])
            { "day" => day, "pieces" => rows.map do |row|
              piece = JSON.parse(row.fetch("metadata")).fetch("content").fetch("pieces").find { |item| item.fetch("id") == row.fetch("piece_id") }
              { "id" => piece.fetch("id"), "body" => piece.fetch("body"), "href" => "/#{WeblogAuthoring.encoded_route(row.fetch('route'))}#piece-#{piece.fetch('id')}" }
            end }
          end
          { "days" => days, "cursor" => dates.length > 10 ? dates.fetch(9) : nil }
        end
      end
    rescue ArgumentError => error
      raise DraftStore::Error, error.message
    end

    private

    def index_piece_mentions(db, article_id, version_id, metadata)
      content = metadata["content"]
      return unless metadata["page_type"] == "date" && content && content["format"] == "pieces"
      day = metadata["page_date"].to_s.empty? ? metadata.fetch("title") : metadata.fetch("page_date")
      content.fetch("pieces").each_with_index do |piece, position|
        names = PieceMentions.names(piece.fetch("body"))
        names.each do |name|
          db.query("INSERT INTO #{db.prefix}article_piece_links (version_id, article_id, piece_id, target_name, day, position) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (version_id, piece_id, target_name) DO NOTHING", [version_id, article_id, piece.fetch("id"), name, day, position])
        end
      end
    end
  end

  class MentionedByDays
    def initialize(store:, database:)
      @store = store
      @database = database
    end

    def call(route, before: nil)
      result = @store.mentioned_by_days(route, before:)
      result.fetch("days").each do |day|
        day.fetch("pieces").each do |piece|
          body = piece.delete("body")
          names = WeblogAuthoring.extract_wiki_links(body).map(&:name).uniq
          piece["html"] = MarkdownRenderer.new(pages: @database.find_pages_by_routes(names)).render(body, mode: "public", progressive: true, image_dimensions: ->(src) { @database.find_image_dimensions(src) }).html
        end
      end
      result
    end
  end
end
