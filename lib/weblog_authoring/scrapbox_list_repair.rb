# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "pathname"

ENV["PGSSLROOTCERT"] ||= OpenSSL::X509::DEFAULT_CERT_FILE

require "aurora_dsql_pg"

module WeblogAuthoring
  class ScrapboxListRepair
    SCHEMA = "weblog_authoring"
    BATCH_SIZE = 25
    RepairPage = Data.define(:name, :expected_body_hash, :replacement_body, :replacement_body_hash)
    RepairResult = Data.define(:name, :status, :id, :current_body_hash, :expected_body_hash, :replacement_body_hash)

    def initialize(host:, before_path:, corrected_path:, connector: AuroraDsql::Pg)
      @host = host
      @before_path = Pathname(before_path)
      @corrected_path = Pathname(corrected_path)
      @connector = connector
      @pages = load_repair_pages
    end

    def scan
      with_connection do |connection|
        @pages.map { |page| inspect_page(connection, page) }
      end
    end

    def apply
      connection = @connector.connect(host: @host)
      results = []
      @pages.each_slice(BATCH_SIZE) do |batch|
        connection.transaction do
          batch.each { |page| results << repair_page(connection, page) }
        end
      end
      results
    ensure
      connection&.close
    end

    private

    def with_connection
      connection = @connector.connect(host: @host)
      yield connection
    ensure
      connection&.close
    end

    def load_repair_pages
      before_pages = load_pages(@before_path)
      corrected_pages = load_pages(@corrected_path)
      names = before_pages.keys
      raise ArgumentError, "Scrapbox export pages do not match" unless names.sort == corrected_pages.keys.sort

      names.filter_map do |name|
        before_body = body_from_page(before_pages.fetch(name))
        replacement_body = body_from_page(corrected_pages.fetch(name))
        next if before_body == replacement_body

        RepairPage.new(
          name:,
          expected_body_hash: Digest::SHA256.hexdigest(before_body),
          replacement_body:,
          replacement_body_hash: Digest::SHA256.hexdigest(replacement_body)
        )
      end
    end

    def load_pages(path)
      raise ArgumentError, "Scrapbox export does not exist: #{path}" unless path.file?

      payload = JSON.parse(path.read(encoding: "UTF-8"))
      pages = payload.fetch("pages")
      pages.to_h do |page|
        name = page.fetch("title")
        raise ArgumentError, "Scrapbox page title must be a string" unless name.is_a?(String)

        [name, page]
      end
    rescue JSON::ParserError, KeyError, TypeError => error
      raise ArgumentError, "invalid Scrapbox export: #{path}: #{error.message}"
    end

    def body_from_page(page)
      lines = page.fetch("lines")
      raise ArgumentError, "Scrapbox page lines must be an array" unless lines.is_a?(Array)

      lines.drop(1).map do |line|
        case line
        when String then line
        when Hash then line.fetch("text")
        else raise ArgumentError, "Scrapbox page line must be a string or object"
        end
      end.join("\n")
    end

    def inspect_page(connection, page)
      row = find_page(connection, page.name)
      return result(page, :missing, nil, nil) unless row

      status = row.fetch("body_hash") == page.expected_body_hash ? :eligible : :edited
      result(page, status, row.fetch("id"), row.fetch("body_hash"))
    end

    def repair_page(connection, page)
      row = find_page(connection, page.name)
      return result(page, :missing, nil, nil) unless row
      return result(page, :edited, row.fetch("id"), row.fetch("body_hash")) unless
        row.fetch("body_hash") == page.expected_body_hash

      # A migration repair changes representation, not the article's chronology.
      # Preserve updated_at so feeds and update-ordered views do not treat repaired records as newly edited.
      updated = connection.exec_params(
        <<~SQL,
          UPDATE #{SCHEMA}.pages
          SET body_hash = $1, is_empty = $2, body = $3
          WHERE id = $4 AND page_type = 'named' AND name = $5 AND body_hash = $6
        SQL
        [
          page.replacement_body_hash, page.replacement_body.strip.empty?, page.replacement_body,
          row.fetch("id"), page.name, page.expected_body_hash,
        ]
      )
      return result(page, :conflict, row.fetch("id"), page.expected_body_hash) unless updated.cmd_tuples == 1

      result(page, :repaired, row.fetch("id"), page.expected_body_hash)
    end

    def find_page(connection, name)
      result = connection.exec_params(
        <<~SQL,
          SELECT id, name, body_hash
          FROM #{SCHEMA}.pages
          WHERE page_type = 'named' AND name = $1
          LIMIT 1
        SQL
        [name]
      )
      result.ntuples.zero? ? nil : result[0]
    end

    def result(page, status, id, current_body_hash)
      RepairResult.new(
        name: page.name,
        status:,
        id:,
        current_body_hash:,
        expected_body_hash: page.expected_body_hash,
        replacement_body_hash: page.replacement_body_hash
      )
    end
  end
end
