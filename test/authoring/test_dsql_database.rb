# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/dsql_database"

class DsqlDatabaseTest < Minitest::Test
  FIXED_TIME = Time.iso8601("2026-08-22T12:00:00+09:00")

  class Result
    include Enumerable

    def initialize(rows = [])
      @rows = rows
    end

    def each(&)
      @rows.each(&)
    end

    def [](index)
      @rows[index]
    end

    def ntuples
      @rows.length
    end
  end

  class Connection
    attr_reader :links

    def initialize
      @pages = {}
      @links = []
    end

    def transaction
      yield
    end

    def exec(statement)
      return Result.new(sorted_pages) if statement.include?("ORDER BY created_at DESC")

      raise "unexpected SQL: #{statement}"
    end

    def exec_params(statement, params)
      case statement
      when /WHERE id = \$1/
        Result.new([@pages[params.fetch(0)]].compact)
      when /WHERE \(page_type = 'date'/
        Result.new(@pages.values.select { |page| page.fetch("name") == params.fetch(0) })
      when /SELECT id FROM weblog_authoring\.pages WHERE page_type/
        Result.new(@pages.values.filter_map do |page|
          { "id" => page.fetch("id") } if page.fetch("name") == params.fetch(1, params.fetch(0))
        end)
      when /INSERT INTO weblog_authoring\.pages/
        store_page(params)
        Result.new
      when /UPDATE weblog_authoring\.pages/
        update_page(params)
        Result.new
      when /DELETE FROM weblog_authoring\.links/
        @links.reject! { |link| link.fetch(:source_id) == params.fetch(0) }
        Result.new
      when /INSERT INTO weblog_authoring\.links/
        @links << { source_id: params.fetch(0), target_name: params.fetch(2) }
        Result.new
      else
        raise "unexpected SQL: #{statement}"
      end
    end

    private

    def sorted_pages
      @pages.values.sort_by { |page| page.fetch("created_at") }.reverse
    end

    def store_page(values)
      keys = %w[
        id page_type name page_date title status created_at updated_at published_at
        path body_hash is_empty body
      ]
      @pages[values.fetch(0)] = keys.zip(values).to_h
    end

    def update_page(values)
      page = @pages.fetch(values.fetch(6))
      page.merge!(
        "status" => values.fetch(0),
        "updated_at" => values.fetch(1),
        "published_at" => values.fetch(2),
        "body_hash" => values.fetch(3),
        "is_empty" => values.fetch(4),
        "body" => values.fetch(5)
      )
    end
  end

  class Pool
    attr_reader :connection

    def initialize
      @connection = Connection.new
    end

    def with
      yield @connection
    end

    def shutdown; end
  end

  def test_saves_reads_and_lists_page_documents
    database = dsql_database
    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "date",
      title: "DSQLの記事",
      body: "本文 [[リンク先]]"
    ))

    assert_equal page, database.find(page.id)
    assert_equal page, database.find_route("/DSQLの記事")
    assert_equal [page], database.list_pages
    assert_equal ["リンク先"], page.links.map(&:name)
    assert_equal [{ source_id: page.id, target_name: "リンク先" }], @pool.connection.links
  end

  def test_updates_existing_page_with_optimistic_timestamp
    database = dsql_database
    page = database.save(WeblogAuthoring::SaveRequest.new(
      page_type: "named", name: "DSQLの記事", body: "最初"
    ))
    updated = database.save(WeblogAuthoring::SaveRequest.new(
      page_id: page.id,
      page_type: page.page_type,
      name: page.name,
      body: "更新",
      expected_updated_at: page.updated_at
    ))

    assert_equal "更新", updated.body
    assert_equal updated, database.find(page.id)
  end

  private

  def dsql_database
    @pool = Pool.new
    WeblogAuthoring::DsqlDatabase.new(
      host: "cluster.dsql.ap-northeast-1.on.aws",
      content_dir: Pathname("content"),
      clock: -> { FIXED_TIME },
      pool: @pool
    )
  end
end
