# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "draft_store"
require_relative "names"

module WeblogAuthoring
  class DraftPublication
    def self.remote(store:, lambda_client:, function_name:)
      invoke = lambda do |payload|
        response = lambda_client.invoke(function_name:, invocation_type: "RequestResponse", payload: JSON.generate(payload))
        raise DraftStore::Error.new("公開版の復元に失敗しました。", 503) if response.function_error
        JSON.parse(response.payload.read)
      rescue Aws::Lambda::Errors::ServiceError
        raise DraftStore::Error.new("公開版の復元に失敗しました。", 503)
      end
      reconstruct_many = lambda do |jobs|
        invoke.call("operation" => "publication_batch", "article_ids" => jobs.map { |job| job.fetch("article_id") })
      end
      new(store:, reconstruct_many:) do |job|
        invoke.call("operation" => "publication", "article_id" => job.fetch("article_id"))
      end
    end

    def self.local(store:)
      root = File.expand_path("../..", __dir__)
      tsx = resolve_local_dependency(root, "node_modules/tsx/dist/cli.mjs")
      new(store:) do |job|
        output, error, status = Open3.capture3("node", tsx, File.join(root, "lambda/draft_worker/local.ts"), stdin_data: JSON.generate(job))
        raise DraftStore::Error.new("公開版の復元に失敗しました: #{error[0, 200]}", 503) unless status.success?
        JSON.parse(output)
      end
    end

    def self.resolve_local_dependency(root, relative_path)
      Pathname(root).expand_path.ascend do |directory|
        candidate = directory.join(relative_path)
        return candidate.to_s if candidate.file?
      end
      File.join(root, relative_path)
    end

    def initialize(store:, reconstruct_many: nil, &reconstruct)
      @store = store
      @reconstruct = reconstruct
      @reconstruct_many = reconstruct_many
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

    # Listing must compare the same normalized content as publication, without
    # calculating a rename batch or accepting a publication.
    def working_content_hash(id)
      verified_content(id).slice("content_hash", "through")
    end

    def working_content_hashes(ids)
      return ids.to_h { |id| [id, working_content_hash(id)] } unless @reconstruct_many
      jobs = ids.map { |id| reconstruction_job(id) }
      results = @reconstruct_many.call(jobs)
      raise DraftStore::Error.new("公開版の復元に失敗しました。", 503) unless results.is_a?(Array) && results.length == jobs.length
      jobs.zip(results).to_h { |job, result| [job.fetch("article_id"), verified_result(job, result).slice("content_hash", "through")] }
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
      job = reconstruction_job(id)
      verified_result(job, @reconstruct.call(job))
    end

    def reconstruction_job(id)
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
      job.merge("updates" => updates)
    end

    def verified_result(job, result)
      id = job.fetch("article_id")
      unless result.fetch("article_id") == id && result.fetch("protocol") == job.fetch("protocol") && result.fetch("generation") == job.fetch("generation") && result.fetch("through") == job.fetch("through")
        raise DraftStore::Error.new("復元した版が一致しません。", 409)
      end
      body = result.fetch("markdown").gsub("\r\n", "\n")
      metadata = job.fetch("metadata").transform_values { |field| field.fetch("value") }
      metadata["title"] = metadata.fetch("title").strip
      metadata["cover_image_url"] = nil unless metadata.fetch("cover_mode") == "explicit"
      route = WeblogAuthoring.validate_page_name(DraftStore.working_route(metadata))
      raise DraftStore::Error, "このURLはシステムが使用しています。" if %w[draft-editor draft-offline.js published].include?(route.split("/").first)
      raise DraftStore::Error, "日記の日付はYYYY-MM-DDで指定してください。" if metadata.fetch("page_type") == "date" && !WeblogAuthoring::DATE_NAME.match?(route)
      Date.iso8601(route) if metadata.fetch("page_type") == "date"
      content = [body, *metadata.values_at("title", "page_type", "cover_mode", "cover_image_url")]
      content << metadata["page_date"] if metadata["page_type"] == "date" && !metadata["page_date"].to_s.empty?
      hash = Digest::SHA256.hexdigest(JSON.generate(content))
      { "body" => body, "metadata" => metadata, "route" => route, "content_hash" => hash,
        "through" => job.fetch("through"), "metadata_revisions" => job.fetch("metadata").transform_values { |field| field.fetch("revision") }, }
    rescue ArgumentError => error
      raise DraftStore::Error, error.message
    end
  end
end
