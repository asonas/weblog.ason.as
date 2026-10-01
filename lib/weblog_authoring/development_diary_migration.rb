# frozen_string_literal: true

require "open3"
require_relative "draft_publication"

module WeblogAuthoring
  class DevelopmentDiaryMigration
    def initialize(store:)
      @store = store
    end

    def migrate(id, apply: false)
      job = @store.checkpoint_job(id)
      raise DraftStore::Error, "Only diaries can be migrated" unless job.dig("metadata", "page_type", "value") == "date"
      return { "article_id" => id, "status" => "already_pieces" } if job["format"] == "pieces"
      cursor = job.fetch("expected_checkpoint")
      updates = []
      while cursor < job.fetch("through")
        page = @store.read(id, "cursor" => cursor.to_s, "through" => job.fetch("through").to_s)
        raise DraftStore::Error.new("Draft history changed; retry migration", 409) if page["checkpoint"] || page.fetch("cursor") <= cursor
        updates.concat(page.fetch("updates"))
        cursor = page.fetch("cursor")
      end
      root = File.expand_path("../..", __dir__)
      tsx = DraftPublication.resolve_local_dependency(root, "node_modules/tsx/dist/cli.mjs")
      output, error, status = Open3.capture3("node", tsx, File.join(root, "scripts/seed-diary-piece.mjs"), stdin_data: JSON.generate(job.merge("updates" => updates)))
      raise DraftStore::Error, "Diary reconstruction failed: #{error[0, 200]}" unless status.success?
      seed = JSON.parse(output)
      @store.convert_legacy_diary(id, job, seed) if apply
      { "article_id" => id, "title" => job.dig("metadata", "title", "value"), "head" => job.fetch("through"), "body_digest" => seed.fetch("body_digest"), "body_bytes" => seed.fetch("body_bytes"), "tags" => seed.fetch("tags"), "status" => apply ? "migrated" : "planned" }
    end
  end
end
