# frozen_string_literal: true

require_relative "names"
require_relative "models"
require_relative "links"

module WeblogAuthoring
  module DraftRenames
    def setup_renames(db)
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_route_reservations (route TEXT PRIMARY KEY, article_id TEXT NOT NULL)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_redirects (route TEXT PRIMARY KEY, article_id TEXT NOT NULL)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_rename_batches (id TEXT PRIMARY KEY, revision INTEGER NOT NULL)")
      db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_rename_members (batch_id TEXT NOT NULL, article_id TEXT NOT NULL, version_id TEXT NOT NULL, previous_id TEXT NOT NULL, html_key TEXT, PRIMARY KEY (batch_id, article_id))")
    end

    def rename_impact(id, route)
      collection = published_collection
      active = collection.fetch("snapshots").find { |snapshot| snapshot.fetch("article_id") == id }
      return nil unless active && active.fetch("route") != route
      references = collection.fetch("snapshots").select do |snapshot|
        snapshot.fetch("article_id") != id && WeblogAuthoring.extract_wiki_links(snapshot.fetch("body")).any? { |link| link.name == active.fetch("route") }
      end
      { "revision" => collection.fetch("revision"), "from" => active.fetch("route"), "to" => route,
        "references" => references.map { |snapshot| { "article_id" => snapshot.fetch("article_id"), "version_id" => snapshot.fetch("id"), "title" => snapshot.dig("metadata", "title") } }, }
    end

    def rename_members(version_id)
      @connect.call { |db| db.query("SELECT * FROM #{db.prefix}draft_rename_members WHERE batch_id = $1 ORDER BY article_id", [version_id]) }
    end

    def stage_rename_versions(impact)
      batch_id = SecureRandom.uuid
      @connect.call { |db| db.query("INSERT INTO #{db.prefix}draft_rename_batches (id, revision) VALUES ($1, $2)", [batch_id, impact.fetch("revision")]) }
      impact.fetch("references").each do |reference|
        source = publication_snapshot(reference.fetch("article_id"), reference.fetch("version_id"))
        body = WeblogAuthoring.replace_wiki_links(source.fetch("body"), old_name: impact.fetch("from"), new_name: impact.fetch("to"))
        metadata = source.fetch("metadata")
        content = [body, *metadata.values_at("title", "page_type", "cover_mode", "cover_image_url")]
        content << metadata["page_date"] if metadata["page_type"] == "date" && !metadata["page_date"].to_s.empty?
        hash = Digest::SHA256.hexdigest(JSON.generate(content))
        replacement = SecureRandom.uuid
        # Bodies commit individually; acceptance and activation only touch pointers.
        @connect.call do |db|
          db.transaction do
            db.query("INSERT INTO #{db.prefix}draft_published_versions (id, article_id, content_hash, body, metadata, route, created_at, article_created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)", [replacement, source.fetch("article_id"), hash, body, JSON.generate(metadata), source.fetch("route"), Time.now.utc.iso8601(6), source.fetch("article_created_at")])
            db.query("INSERT INTO #{db.prefix}draft_rename_members (batch_id, article_id, version_id, previous_id) VALUES ($1, $2, $3, $4)", [batch_id, source.fetch("article_id"), replacement, source.fetch("id")])
          end
        end
      end
      batch_id
    end

    def stage_rename_html(batch_id, id, key)
      @connect.call { |db| db.query("UPDATE #{db.prefix}draft_rename_members SET html_key = $1 WHERE batch_id = $2 AND article_id = $3", [key, batch_id, id]) }
    end

    def finish_rename(id, version_id)
      @connect.call do |db|
        db.transaction do
          job = db.query("SELECT * FROM #{db.prefix}draft_publication_jobs WHERE article_id = $1 AND id = $2", [id, version_id]).first
          raise DraftStore::Error.new("Publication not found", 404) unless job
          next job if %w[completed superseded].include?(job.fetch("status"))
          batch = db.query("SELECT revision FROM #{db.prefix}draft_rename_batches WHERE id = $1", [version_id]).first
          revision = db.query("SELECT revision FROM #{db.prefix}draft_publication_clock WHERE id = 1").first.fetch("revision").to_i
          members = db.query("SELECT * FROM #{db.prefix}draft_rename_members WHERE batch_id = $1 ORDER BY article_id", [version_id])
          heads = members.to_h do |member|
            article_id = member.fetch("article_id")
            [article_id, db.query("SELECT * FROM #{db.prefix}draft_publication_heads WHERE article_id = $1", [article_id]).first]
          end
          valid = revision == batch.fetch("revision").to_i && members.all? do |member|
            head = heads.fetch(member.fetch("article_id"))
            head.fetch("active_id") == member.fetch("previous_id") && head.fetch("latest_id") == (member.fetch("article_id") == id ? version_id : member.fetch("previous_id"))
          end
          unless valid
            db.query("UPDATE #{db.prefix}draft_publication_jobs SET status = 'superseded' WHERE id = $1", [version_id])
            next job.merge("status" => "superseded")
          end
          raise DraftStore::Error.new("一括公開のHTML配置が完了していません。", 409) if members.any? { |member| member["html_key"].nil? }
          now = Time.now.utc.iso8601(6)
          old = snapshot_from(db, id, heads.fetch(id).fetch("active_id"))
          db.query("INSERT INTO #{db.prefix}draft_redirects (route, article_id) VALUES ($1, $2) ON CONFLICT (route) DO NOTHING", [old.fetch("route"), id])
          members.each do |member|
            article_id = member.fetch("article_id")
            updated_at = article_id == id ? now : heads.fetch(article_id).fetch("updated_at")
            db.query("UPDATE #{db.prefix}draft_publication_heads SET active_id = $1, latest_id = $1, updated_at = $2 WHERE article_id = $3", [member.fetch("version_id"), updated_at, article_id])
            db.query("INSERT INTO #{db.prefix}draft_publication_jobs (id, article_id, status, html_key) VALUES ($1, $2, 'completed', $3) ON CONFLICT (id) DO UPDATE SET status = 'completed', html_key = $3, error = NULL", [member.fetch("version_id"), article_id, member.fetch("html_key")])
          end
          db.query("UPDATE #{db.prefix}draft_publication_clock SET revision = revision + 1 WHERE id = 1")
          job.merge("status" => "completed", "error" => nil)
        end
      end
    end

    def published_redirect(route)
      resolve_published_route(route)["redirect"]
    end

    def resolve_published_route(route)
      @connect.call do |db|
        db.transaction do
          owner = db.query("SELECT article_id FROM #{db.prefix}draft_publication_routes WHERE route = $1", [route]).first
          next {} unless owner
          id = owner.fetch("article_id")
          head = db.query("SELECT * FROM #{db.prefix}draft_publication_heads WHERE article_id = $1", [id]).first
          next {} unless head && head["active_id"]
          snapshot = snapshot_from(db, id, head.fetch("active_id"))
          if snapshot.fetch("route") == route
            html = db.query("SELECT html_key, html_digest FROM #{db.prefix}draft_html_outputs WHERE article_id = $1 AND version_id = $2", [id, head.fetch("active_id")]).first || {}
            { "snapshot" => snapshot.merge(head.slice("published_at", "updated_at"), html) }
          elsif db.query("SELECT route FROM #{db.prefix}draft_redirects WHERE route = $1 AND article_id = $2", [route, id]).any?
            { "redirect" => snapshot.fetch("route") }
          else
            {}
          end
        end
      end
    end

    private

    def reserve_working_route(db, id, title)
      route = title.to_s.strip
      db.query("DELETE FROM #{db.prefix}draft_route_reservations WHERE article_id = $1 AND route <> $2", [id, route])
      return if route.empty?
      begin
        WeblogAuthoring.validate_page_name(route)
      rescue ArgumentError
        return
      end
      owner = db.query("SELECT article_id FROM #{db.prefix}draft_publication_routes WHERE route = $1", [route]).first
      raise DraftStore::Error.new("このURLは別の記事で使用中です。", 409) if owner && owner.fetch("article_id") != id
      db.query("INSERT INTO #{db.prefix}draft_route_reservations (route, article_id) VALUES ($1, $2) ON CONFLICT (route) DO NOTHING", [route, id])
      owner = db.query("SELECT article_id FROM #{db.prefix}draft_route_reservations WHERE route = $1", [route]).first
      raise DraftStore::Error.new("このURLは別の下書きが予約しています。", 409) unless owner.fetch("article_id") == id
    end

    def accept_rename_batch(db, id, version_id, active, impact)
      revision = db.query("SELECT revision FROM #{db.prefix}draft_publication_clock WHERE id = 1").first.fetch("revision").to_i
      raise DraftStore::Error.new("参照元の公開版が変更されました。影響範囲を再確認してください。", 409) unless revision == impact.fetch("revision")
      db.query("UPDATE #{db.prefix}draft_publication_clock SET revision = revision WHERE id = 1")
      db.query("INSERT INTO #{db.prefix}draft_rename_members (batch_id, article_id, version_id, previous_id) VALUES ($1, $2, $3, $4)", [version_id, id, version_id, active.fetch("id")])
      impact.fetch("references").each do |reference|
        article_id = reference.fetch("article_id")
        head = db.query("SELECT active_id, latest_id FROM #{db.prefix}draft_publication_heads WHERE article_id = $1", [article_id]).first
        unless head.fetch("active_id") == reference.fetch("version_id") && head.fetch("latest_id") == head.fetch("active_id")
          raise DraftStore::Error.new("参照元の公開処理が進行中です。完了後に再確認してください。", 409)
        end
      end
    end
  end
end
