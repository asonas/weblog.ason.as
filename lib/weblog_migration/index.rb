# frozen_string_literal: true

require "date"
require "fileutils"
require "pathname"
require "sqlite3"

module WeblogMigration
  class LinkIndex
    def initialize(connection)
      @connection = connection
    end

    def find_backlinks(target_id)
      @connection.execute(
        "SELECT source_id FROM edges WHERE target_id = ? ORDER BY source_id",
        [target_id]
      ).map(&:first)
    end

    def directions_between(first_id, second_id)
      directions = []
      incoming = @connection.get_first_value(
        "SELECT 1 FROM edges WHERE source_id = ? AND target_id = ? LIMIT 1",
        second_id,
        first_id
      )
      outgoing = @connection.get_first_value(
        "SELECT 1 FROM edges WHERE source_id = ? AND target_id = ? LIMIT 1",
        first_id,
        second_id
      )
      directions << "incoming" unless incoming.nil?
      directions << "outgoing" unless outgoing.nil?
      directions
    end

    def neighbors(root_id, direction: "both", depth: 1, start_date: nil, end_date: nil)
      return [] if depth <= 0

      visited = { root_id => true }
      frontier = [root_id]
      found = []
      depth.times do
        next_frontier = []
        frontier.each do |node_id|
          adjacent(node_id, direction).each do |neighbor_id|
            next if visited[neighbor_id]

            visited[neighbor_id] = true
            next_frontier << neighbor_id
            found << neighbor_id if matches_date_range?(neighbor_id, start_date, end_date)
          end
        end
        frontier = next_frontier
        break if frontier.empty?
      end
      found
    end

    private

    def adjacent(node_id, direction)
      neighbors = []
      if %w[outgoing both].include?(direction)
        neighbors.concat(@connection.execute("SELECT target_id FROM edges WHERE source_id = ?", [node_id]).map(&:first))
      end
      if %w[incoming both].include?(direction)
        neighbors.concat(@connection.execute("SELECT source_id FROM edges WHERE target_id = ?", [node_id]).map(&:first))
      end
      neighbors.uniq.sort
    end

    def matches_date_range?(node_id, start_date, end_date)
      return true if start_date.nil? && end_date.nil?

      value = @connection.get_first_value("SELECT created_at FROM posts WHERE id = ?", node_id)
      return true if value.nil? && !post_exists?(node_id)
      return false if value.nil?

      value = value[0, 10]
      start_text = date_text(start_date)
      end_text = date_text(end_date)
      (start_text.nil? || value >= start_text) && (end_text.nil? || value <= end_text)
    end

    def post_exists?(node_id)
      !@connection.get_first_value("SELECT 1 FROM posts WHERE id = ?", node_id).nil?
    end

    def date_text(value)
      return nil if value.nil?
      return value.iso8601 if value.respond_to?(:iso8601)

      value.to_s
    end
  end

  module Index
    module_function

    def build_index(normalized, database_path)
      database_path = Pathname(database_path)
      FileUtils.mkdir_p(database_path.dirname)
      FileUtils.rm_f(database_path)
      connection = SQLite3::Database.new(database_path.to_s)
      connection.execute_batch(<<~SQL)
        CREATE TABLE posts (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at TEXT,
          updated_at TEXT,
          published_at TEXT,
          visibility TEXT NOT NULL,
          path TEXT NOT NULL
        );
        CREATE TABLE assets (
          id TEXT PRIMARY KEY,
          source_path TEXT NOT NULL,
          mime_type TEXT,
          path TEXT
        );
        CREATE TABLE edges (
          source_id TEXT NOT NULL,
          target_id TEXT NOT NULL,
          edge_kind TEXT NOT NULL,
          position INTEGER NOT NULL,
          PRIMARY KEY (source_id, target_id, edge_kind, position)
        );
        CREATE TABLE issues (
          kind TEXT NOT NULL,
          source TEXT NOT NULL,
          detail TEXT NOT NULL
        );
        CREATE INDEX edges_source_idx ON edges (source_id);
        CREATE INDEX edges_target_idx ON edges (target_id);
        CREATE INDEX posts_created_idx ON posts (created_at);
      SQL

      normalized.posts.each do |post|
        frontmatter = post.frontmatter
        connection.execute(
          "INSERT INTO posts (id, title, created_at, updated_at, published_at, visibility, path) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [
            post.id,
            frontmatter.fetch("title"),
            frontmatter["created_at"],
            frontmatter["updated_at"],
            frontmatter["published_at"],
            frontmatter.fetch("visibility"),
            "posts/#{post.id}.md"
          ]
        )
        source_project = frontmatter.fetch("source_project").to_s
        post.links.each_with_index do |target_title, position|
          target_id = normalized.mapping["#{source_project}\0#{target_title}"]
          next if target_id.nil?

          connection.execute("INSERT INTO edges VALUES (?, ?, ?, ?)", [post.id, target_id, "post_reference", position])
        end
        post.asset_references.each_with_index do |source_path, position|
          asset_id = AssetManifest.stable_asset_id(source_path)
          connection.execute("INSERT OR IGNORE INTO assets (id, source_path) VALUES (?, ?)", [asset_id, source_path])
          connection.execute("INSERT INTO edges VALUES (?, ?, ?, ?)", [post.id, asset_id, "asset_reference", position])
        end
        post.external_urls.each_with_index do |url, position|
          asset_id = AssetManifest.stable_url_asset_id(url)
          connection.execute("INSERT OR IGNORE INTO assets (id, source_path) VALUES (?, ?)", [asset_id, url])
          connection.execute("INSERT INTO edges VALUES (?, ?, ?, ?)", [post.id, asset_id, "external_url", position])
        end
        post.issues.each do |issue|
          connection.execute("INSERT INTO issues VALUES (?, ?, ?)", [issue.kind, issue.source, issue.detail])
        end
      end
      LinkIndex.new(connection)
    end
  end
end
