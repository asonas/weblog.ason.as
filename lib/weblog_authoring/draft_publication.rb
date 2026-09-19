# frozen_string_literal: true

require "open3"
require_relative "draft_store"
require_relative "names"

module WeblogAuthoring
  class DraftPublication
    def self.remote(store:, lambda_client:, function_name:)
      new(store:) do |job|
        response = lambda_client.invoke(function_name:, invocation_type: "RequestResponse", payload: JSON.generate("operation" => "publication", "article_id" => job.fetch("article_id")))
        raise DraftStore::Error.new("公開版の復元に失敗しました。", 503) if response.function_error
        JSON.parse(response.payload.read)
      end
    end

    def self.local(store:)
      root = File.expand_path("../..", __dir__)
      new(store:) do |job|
        output, error, status = Open3.capture3("node", File.join(root, "node_modules/tsx/dist/cli.mjs"), File.join(root, "lambda/draft_worker/local.ts"), stdin_data: JSON.generate(job))
        raise DraftStore::Error.new("公開版の復元に失敗しました: #{error[0, 200]}", 503) unless status.success?
        JSON.parse(output)
      end
    end

    def initialize(store:, &reconstruct)
      @store = store
      @reconstruct = reconstruct
    end

    def prepare(id)
      verified = verified_content(id)
      current = @store.published_snapshot(id)
      state = if current.nil?
                "draft"
              elsif current.fetch("content_hash") == verified.fetch("content_hash")
                "public"
              else
                "unpublished_changes"
              end
      { "protocol" => 1, "generation" => 1, "head" => verified.fetch("through"),
        "metadata_revisions" => verified.fetch("metadata_revisions"), "content_hash" => verified.fetch("content_hash"),
        "article_state" => state, "rename" => @store.rename_impact(id, verified.fetch("route")), }
    end

    def accept(id, request)
      request = request.slice("protocol", "generation", "head", "metadata_revisions", "content_hash", "request_id", "rename")
      raise DraftStore::Error, "Invalid publication ID" unless request["request_id"].is_a?(String) && /\A[a-zA-Z0-9-]{1,80}\z/.match?(request["request_id"])
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(request.sort.to_h))
      previous = @store.publication_receipt(id, request.fetch("request_id"), fingerprint)
      return previous if previous
      verified = verified_content(id)
      impact = @store.rename_impact(id, verified.fetch("route"))
      raise DraftStore::Error.new("名前変更の影響範囲を再確認してください。", 409) unless request["rename"] == impact
      batch_id = @store.stage_rename_versions(impact) if impact
      @store.accept_verified_publication(id, request, verified.merge("rename" => impact, "batch_id" => batch_id))
    end

    def complete(id, version_id)
      job = @store.publication_job(id, version_id)
      return job if %w[completed superseded].include?(job.fetch("status"))
      members = @store.rename_members(version_id)
      unless members.empty?
        members.each do |member|
          next if member["html_key"]
          snapshot = @store.publication_snapshot(member.fetch("article_id"), member.fetch("version_id"))
          key = yield snapshot
          raise DraftStore::Error, "HTML placement was not acknowledged" unless key.is_a?(String) && !key.empty?
          @store.stage_rename_html(version_id, member.fetch("article_id"), key)
        end
        return @store.finish_rename(id, version_id)
      end
      snapshot = @store.publication_snapshot(id, version_id)
      key = yield snapshot
      raise DraftStore::Error, "HTML placement was not acknowledged" unless key.is_a?(String) && !key.empty?
      @store.finish_publication(id, version_id, key)
    rescue StandardError => error
      @store.fail_publication(id, version_id, error.message)
      raise
    end

    private

    def verified_content(id)
      job = @store.checkpoint_job(id)
      cursor = job.fetch("expected_checkpoint")
      updates = []
      while cursor < job.fetch("through")
        page = @store.read(id, { "cursor" => cursor.to_s, "through" => job.fetch("through").to_s })
        if page["checkpoint"] || page.fetch("cursor") <= cursor
          raise DraftStore::Error.new("保存履歴が整理されました。もう一度公開内容を確認してください。", 409)
        end
        updates.concat(page.fetch("updates"))
        cursor = page.fetch("cursor")
      end
      result = @reconstruct.call(job.merge("updates" => updates))
      unless result.fetch("article_id") == id && result.fetch("protocol") == job.fetch("protocol") && result.fetch("generation") == job.fetch("generation") && result.fetch("through") == job.fetch("through")
        raise DraftStore::Error.new("復元した版が一致しません。", 409)
      end
      body = result.fetch("markdown").gsub("\r\n", "\n")
      metadata = job.fetch("metadata").transform_values { |field| field.fetch("value") }
      metadata["title"] = metadata.fetch("title").strip
      metadata["cover_image_url"] = nil unless metadata.fetch("cover_mode") == "explicit"
      route = WeblogAuthoring.validate_page_name(metadata.fetch("title"))
      raise DraftStore::Error, "このURLはシステムが使用しています。" if %w[draft-editor published].include?(route.split("/").first)
      raise DraftStore::Error, "日記の日付はYYYY-MM-DDで指定してください。" if metadata.fetch("page_type") == "date" && !WeblogAuthoring::DATE_NAME.match?(route)
      Date.iso8601(route) if metadata.fetch("page_type") == "date"
      hash = Digest::SHA256.hexdigest(JSON.generate([body, *metadata.values_at("title", "page_type", "cover_mode", "cover_image_url")]))
      { "body" => body, "metadata" => metadata, "route" => route, "content_hash" => hash,
        "through" => job.fetch("through"), "metadata_revisions" => job.fetch("metadata").transform_values { |field| field.fetch("revision") }, }
    rescue ArgumentError => error
      raise DraftStore::Error, error.message
    end
  end
end
