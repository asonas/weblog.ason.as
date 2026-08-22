# frozen_string_literal: true

require_relative "../test_helper"
require "sqlite3"
require "weblog_authoring/dsql_importer"

class DsqlImporterTest < Minitest::Test
  Result = Data.define(:ntuples)

  class Connection
    attr_reader :pages, :links

    def initialize
      @pages = {}
      @links = []
    end

    def transaction
      yield
    end

    def exec_params(statement, values)
      case statement
      when /SELECT 1 FROM weblog_authoring\.pages/
        Result.new(@pages.key?(values.fetch(0)) ? 1 : 0)
      when /INSERT INTO weblog_authoring\.pages/
        @pages[values.fetch(0)] = values
      when /UPDATE weblog_authoring\.pages/
        @pages[values.fetch(12)] = [values.fetch(12)] + values.first(12)
      when /DELETE FROM weblog_authoring\.links/
        @links.reject! { |link| link.fetch(0) == values.fetch(0) }
      when /UPDATE weblog_authoring\.links SET target_id = NULL/
        @links.map! { |link| link.fetch(1) == values.fetch(0) ? [link.fetch(0), nil, link.fetch(2), link.fetch(3)] : link }
      when /DELETE FROM weblog_authoring\.pages/
        @pages.delete(values.fetch(0))
      when /INSERT INTO weblog_authoring\.links/
        @links << values
      else
        raise "unexpected SQL: #{statement}"
      end
      Result.new(0)
    end

    def close; end
  end

  class Connector
    attr_reader :connection

    def initialize
      @connection = Connection.new
    end

    def connect(host:)
      raise "missing host" if host.empty?

      connection
    end
  end

  def test_imports_pages_and_links_and_can_be_repeated
    Dir.mktmpdir do |directory|
      database_path = Pathname(directory).join("authoring.sqlite3")
      create_source(database_path)
      connector = Connector.new
      importer = WeblogAuthoring::DsqlImporter.new(
        host: "cluster.dsql.ap-northeast-1.on.aws",
        database_path:,
        connector:
      )

      assert_equal({ pages: 2, links: 1, excluded_pages: 0 }, importer.counts)
      assert_equal({ pages: 2, links: 1, excluded_pages: 0 }, importer.run)
      assert_equal({ pages: 2, links: 1, excluded_pages: 0 }, importer.run)
      assert_equal %w[page-1 page-2], connector.connection.pages.keys.sort
      assert_equal [["page-1", "page-2", "リンク先", 0]], connector.connection.links
    end
  end

  def test_filters_and_prunes_pages_not_found_in_the_export
    Dir.mktmpdir do |directory|
      database_path = Pathname(directory).join("authoring.sqlite3")
      export_path = Pathname(directory).join("scrapbox.json")
      create_source(database_path)
      export_path.write(JSON.generate("pages" => [{ "title" => "記事" }]), encoding: "UTF-8")
      connector = Connector.new
      importer = WeblogAuthoring::DsqlImporter.new(
        host: "cluster.dsql.ap-northeast-1.on.aws",
        database_path:,
        export_path:,
        connector:
      )

      unfiltered = WeblogAuthoring::DsqlImporter.new(
        host: "cluster.dsql.ap-northeast-1.on.aws",
        database_path:,
        connector:,
      )
      unfiltered.run
      assert_equal({ pages: 1, links: 1, excluded_pages: 1 }, importer.counts)
      assert_equal({ pages: 1, links: 1, excluded_pages: 1 }, importer.run(prune_excluded: true))
      assert_equal ["page-1"], connector.connection.pages.keys
      assert_equal [["page-1", nil, "リンク先", 0]], connector.connection.links
    end
  end

  private

  def create_source(path)
    database = SQLite3::Database.new(path.to_s)
    database.execute(<<~SQL)
      CREATE TABLE pages (
        id TEXT PRIMARY KEY, page_type TEXT NOT NULL, name TEXT, page_date TEXT,
        title TEXT, status TEXT NOT NULL, created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, published_at TEXT, path TEXT NOT NULL,
        body_hash TEXT NOT NULL, is_empty INTEGER NOT NULL, body TEXT NOT NULL
      )
    SQL
    database.execute(<<~SQL)
      CREATE TABLE links (
        source_id TEXT NOT NULL, target_id TEXT, target_name TEXT NOT NULL,
        position INTEGER NOT NULL, PRIMARY KEY (source_id, position)
      )
    SQL
    pages = [
      [
        "page-1", "named", "記事", nil, nil, "published", "2026-08-22T00:00:00Z",
        "2026-08-22T00:00:00Z", nil, "content/named/記事.md", "hash-1", 0, "本文 [[リンク先]]",
      ],
      [
        "page-2", "named", "リンク先", nil, nil, "published", "2026-08-21T00:00:00Z",
        "2026-08-21T00:00:00Z", nil, "content/named/リンク先.md", "hash-2", 1, "",
      ],
    ]
    pages.each { |page| database.execute("INSERT INTO pages VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", page) }
    database.execute("INSERT INTO links VALUES (?, ?, ?, ?)", ["page-1", "page-2", "リンク先", 0])
  ensure
    database&.close
  end
end
