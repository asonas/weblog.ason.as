# frozen_string_literal: true

require_relative "draft_publication"
require_relative "links"

module WeblogAuthoring
  # Operator-only repair path; it is not loaded by the authoring API.
  class ScrapboxHashtagRepair < DraftStore
    def self.replacement_body(body, differences)
      replacements = {}
      differences.each do |difference|
        before, after = difference.values_at("before", "after")
        [[before, after], [before.sub(/\A\s*- /, ""), after.sub(/\A\s*- /, "")]].each do |old_line, new_line|
          raise Error, "Ambiguous line replacement" if replacements.key?(old_line) && replacements[old_line] != new_line
          replacements[old_line] = new_line
        end
      end
      fence = nil
      body.lines.map do |line|
        marker = WeblogAuthoring::FENCE_PATTERN.match(line)&.[](1)
        fenced = !fence.nil?
        if marker
          if fence.nil?
            fence = marker
          elsif marker[0] == fence[0] && marker.length >= fence.length
            fence = nil
          end
        end
        next line if fenced || marker
        text = line.delete_suffix("\n")
        replacement = replacements[text]
        next line unless replacement
        replacement + (line.end_with?("\n") ? "\n" : "")
      end.join
    end

    def self.prepare(backup, differences)
      snapshot = backup.fetch("snapshot")
      before = snapshot.fetch("body")
      after = replacement_body(before, differences)
      return nil if after == before
      document = backup.fetch("document")
      job = backup.fetch("job")
      metadata = job.fetch("metadata").transform_values { |field| field.fetch("value") }
      raise Error, "Unpublished metadata changes" unless metadata == snapshot.fetch("metadata")
      raise Error, "Draft changed during backup" unless document.fetch("head") == job.fetch("through") && document.fetch("metadata") == job.fetch("metadata")
      root = File.expand_path("../..", __dir__)
      tsx = DraftPublication.resolve_local_dependency(root, "node_modules/tsx/dist/cli.mjs")
      output, error, status = Open3.capture3("node", tsx, File.join(root, "scripts/repair-scrapbox-draft.ts"),
        stdin_data: JSON.generate(job:, before:, after:))
      raise Error, error unless status.success?
      content = [after, *metadata.values_at("title", "page_type", "cover_mode", "cover_image_url")]
      content << metadata["page_date"] if metadata["page_type"] == "date" && !metadata["page_date"].to_s.empty?
      { "before" => snapshot, "document" => document.except("updates"), "body" => after,
        "content_hash" => Digest::SHA256.hexdigest(JSON.generate(content)), "update" => JSON.parse(output), "version_id" => SecureRandom.uuid, }
    end

    def apply_repair(plan, artifact:)
      original = plan.fetch("before")
      id = original.fetch("article_id")
      version = plan.fetch("version_id")
      update = plan.fetch("update")
      data = Base64.strict_decode64(update.fetch("data"))
      raise Error, "Invalid repair update" unless Digest::SHA256.hexdigest(data) == update.fetch("digest") && data.bytesize <= UPDATE_LIMIT && plan.fetch("body").bytesize == update.fetch("body_bytes")
      @connect.call do |db|
        db.transaction do
          current = document(db, id)
          head = db.query("SELECT * FROM #{db.prefix}draft_publication_heads WHERE article_id = $1", [id]).first
          if head && head["active_id"] == version
            repaired = snapshot_from(db, id, version)
            raise Error, "Repair version differs" unless repaired.fetch("body") == plan.fetch("body") && repaired.fetch("content_hash") == plan.fetch("content_hash")
            next "already_repaired"
          end
          expected = plan.fetch("document")
          unless current == expected.except("through", "cursor") && head && head["active_id"] == original.fetch("id") && head["latest_id"] == head["active_id"] && head.slice("updated_at", "published_at") == original.slice("updated_at", "published_at")
            raise Error.new("Draft or publication changed since the repair plan", 409)
          end
          stored = snapshot_from(db, id, head.fetch("active_id"))
          raise Error.new("Published body changed", 409) unless stored.except("html_key", "html_digest", "updated_at", "published_at") == original.except("html_key", "html_digest", "updated_at", "published_at")
          sequence = current.fetch("head") + 1
          # Representation repairs preserve article chronology in both working and published heads.
          changed = db.query("UPDATE #{db.prefix}draft_articles SET head = $1 WHERE id = $2 AND head = $3 RETURNING head", [sequence, id, current.fetch("head")])
          raise Error.new("Draft changed", 409) if changed.empty?
          receipt = { "update_id" => version, "digest" => update.fetch("digest"), "sequence" => sequence, "generation" => 1, "metadata" => current.fetch("metadata") }
          chunks = (data.bytesize + CHUNK_BYTES - 1) / CHUNK_BYTES
          chunks.times do |position|
            db.query("INSERT INTO #{db.prefix}draft_chunks (article_id, update_id, position, data) VALUES ($1, $2, $3, $4)", [id, version, position, Base64.strict_encode64(data.byteslice(position * CHUNK_BYTES, CHUNK_BYTES))])
          end
          fingerprint = update_fingerprint(update.fetch("digest"), update.fetch("body_bytes"), {})
          db.query("INSERT INTO #{db.prefix}draft_updates (article_id, update_id, sequence, digest, fingerprint, receipt, chunks) VALUES ($1, $2, $3, $4, $5, $6, $7)", [id, version, sequence, update.fetch("digest"), fingerprint, JSON.generate(receipt), chunks])
          db.query("INSERT INTO #{db.prefix}draft_published_versions (id, article_id, content_hash, body, metadata, route, created_at, article_created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)", [version, id, plan.fetch("content_hash"), plan.fetch("body"), JSON.generate(original.fetch("metadata")), original.fetch("route"), original.fetch("created_at"), original.fetch("article_created_at")])
          db.query("UPDATE #{db.prefix}draft_publication_heads SET active_id = $1, latest_id = $1 WHERE article_id = $2", [version, id])
          db.query("INSERT INTO #{db.prefix}draft_publication_jobs (id, article_id, status, html_key) VALUES ($1, $2, 'completed', $3)", [version, id, artifact.fetch("html_key")])
          db.query("INSERT INTO #{db.prefix}draft_html_outputs (article_id, version_id, html_key, html_digest) VALUES ($1, $2, $3, $4) ON CONFLICT (article_id) DO UPDATE SET version_id = $2, html_key = $3, html_digest = $4", [id, version, artifact.fetch("html_key"), artifact.fetch("html_digest")])
          db.query("INSERT INTO #{db.prefix}draft_working_hashes (article_id, head, content_hash) VALUES ($1, $2, $3) ON CONFLICT (article_id) DO UPDATE SET head = $2, content_hash = $3", [id, sequence, plan.fetch("content_hash")])
          db.query("UPDATE #{db.prefix}draft_publication_clock SET revision = revision + 1 WHERE id = 1")
          "repaired"
        end
      end
    end
  end
end
