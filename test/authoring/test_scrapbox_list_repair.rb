# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "weblog_authoring/scrapbox_list_repair"

class ScrapboxListRepairTest < Minitest::Test
  Result = Data.define(:rows, :cmd_tuples) do
    include Enumerable

    def each(&)
      rows.each(&)
    end

    def [](index)
      rows[index]
    end

    def ntuples
      rows.length
    end
  end

  class Connection
    attr_reader :pages

    def initialize(pages)
      @pages = pages.to_h { |page| [page.fetch("id"), page.dup] }
    end

    def transaction
      yield
    end

    def exec_params(statement, values)
      case statement
      when /SELECT id, name, body_hash\s+FROM weblog_authoring\.pages/
        page = @pages.values.find do |candidate|
          candidate.fetch("page_type") == "named" && candidate.fetch("name") == values.fetch(0)
        end
        Result.new(page ? [page] : [], 0)
      when /UPDATE weblog_authoring\.pages/
        replacement_hash, is_empty, body, id, name, expected_hash = values
        page = @pages[id]
        return Result.new([], 0) unless page && page.fetch("page_type") == "named"
        return Result.new([], 0) unless page.fetch("name") == name && page.fetch("body_hash") == expected_hash

        page.merge!(
          "body_hash" => replacement_hash,
          "is_empty" => is_empty,
          "body" => body
        )
        Result.new([], 1)
      else
        raise "unexpected SQL: #{statement}"
      end
    end

    def close; end
  end

  class Connector
    attr_reader :connection

    def initialize(pages)
      @connection = Connection.new(pages)
    end

    def connect(host:)
      raise "missing host" if host.empty?

      connection
    end
  end

  def test_scans_eligible_edited_and_missing_pages
    Dir.mktmpdir do |directory|
      before_path, corrected_path = write_exports(directory)
      connector = Connector.new(dsql_pages)
      repair = build_repair(before_path, corrected_path, connector)

      statuses = repair.scan.to_h { |result| [result.name, result.status] }

      assert_equal({
        "修正対象" => :eligible,
        "編集済み" => :edited,
        "欠落" => :missing,
      }, statuses)
    end
  end

  def test_repairs_only_pages_with_the_expected_body_and_preserves_metadata
    Dir.mktmpdir do |directory|
      before_path, corrected_path = write_exports(directory)
      connector = Connector.new(dsql_pages)
      repair = build_repair(before_path, corrected_path, connector)

      results = repair.apply.to_h { |result| [result.name, result.status] }
      repaired = connector.connection.pages.fetch("page-1")
      edited = connector.connection.pages.fetch("page-2")

      assert_equal :repaired, results.fetch("修正対象")
      assert_equal :edited, results.fetch("編集済み")
      assert_equal :missing, results.fetch("欠落")
      assert_equal "毎日更新\n- 項目", repaired.fetch("body")
      assert_equal Digest::SHA256.hexdigest(repaired.fetch("body")), repaired.fetch("body_hash")
      assert_equal "2025-01-02T00:00:00Z", repaired.fetch("updated_at")
      assert_equal "2025-01-01T00:00:00Z", repaired.fetch("created_at")
      assert_equal "本文を追記した", edited.fetch("body")
    end
  end

  private

  def build_repair(before_path, corrected_path, connector)
    WeblogAuthoring::ScrapboxListRepair.new(
      host: "cluster.dsql.ap-northeast-1.on.aws",
      before_path:,
      corrected_path:,
      connector:
    )
  end

  def write_exports(directory)
    before_path = Pathname(directory).join("before.json")
    corrected_path = Pathname(directory).join("corrected.json")
    pages = [
      { "title" => "修正対象", "lines" => %w[修正対象 毎日更新 項目] },
      { "title" => "編集済み", "lines" => %w[編集済み 毎日更新 項目] },
      { "title" => "欠落", "lines" => %w[欠落 毎日更新 項目] },
    ]
    corrected_pages = pages.map do |page|
      page.merge("lines" => page.fetch("lines").dup.tap { |lines| lines[-1] = "- 項目" })
    end
    before_path.write(JSON.generate("pages" => pages), encoding: "UTF-8")
    corrected_path.write(JSON.generate("pages" => corrected_pages), encoding: "UTF-8")
    [before_path, corrected_path]
  end

  def dsql_pages
    [
      dsql_page("page-1", "修正対象", "毎日更新\n項目"),
      dsql_page("page-2", "編集済み", "本文を追記した"),
    ]
  end

  def dsql_page(id, name, body)
    {
      "id" => id,
      "page_type" => "named",
      "name" => name,
      "body" => body,
      "body_hash" => Digest::SHA256.hexdigest(body),
      "is_empty" => body.empty?,
      "status" => "published",
      "created_at" => "2025-01-01T00:00:00Z",
      "updated_at" => "2025-01-02T00:00:00Z",
      "published_at" => "2025-01-02T00:00:00Z",
    }
  end
end
