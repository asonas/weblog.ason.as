# frozen_string_literal: true

require "pathname"
require "json"
require "sqlite3"
require "securerandom"
root = Pathname(__dir__).parent
$LOAD_PATH.unshift(root.join("lib").to_s)
require "weblog_authoring/development_app"

abort "Usage: mise exec -- ruby scripts/prepare-development-draft-reader.rb [--apply]" unless ARGV.empty? || ARGV == ["--apply"]
directory = WeblogAuthoring::DevelopmentApp.shared_development_root(root).join("data/development")
source_path = directory.join("authoring.sqlite3")
draft_path = directory.join("drafts.sqlite3")
abort "Both development databases must exist" unless source_path.file? && draft_path.file?
source = SQLite3::Database.new(source_path.to_s, readonly: true)
drafts = SQLite3::Database.new(draft_path.to_s, readonly: true)
begin
  ids = source.execute("SELECT id FROM pages WHERE status = 'published'").flatten
  published = drafts.execute("SELECT article_id FROM article_publication_heads WHERE active_id IS NOT NULL").flatten
  missing = ids - published
  state = drafts.get_first_value("SELECT state FROM draft_migration_state WHERE id = 1")
  puts JSON.pretty_generate("legacy_articles" => ids.length, "published_articles" => published.length, "missing_ids" => missing, "migration_state" => state)
  abort "Import and verify missing articles before switching readers" unless missing.empty? && %w[verified sealed].include?(state)
ensure
  source.close
  drafts.close
end
if ARGV == ["--apply"]
  suffix = "before-reader-cutover-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}"
  [source_path, draft_path].each do |path|
    backup_path = path.sub_ext(".#{suffix}.sqlite3")
    source = SQLite3::Database.new(path.to_s)
    destination = SQLite3::Database.new(backup_path.to_s)
    backup = SQLite3::Backup.new(destination, "main", source, "main")
    begin
      raise "Development backup failed" unless backup.step(-1) == SQLite3::Constants::ErrorCode::DONE
    ensure
      backup.finish
      source.close
      destination.close
    end
    puts JSON.generate("backup" => backup_path.to_s)
  end
  WeblogAuthoring::DraftStore.sqlite(draft_path).seal_migration
  puts JSON.generate("migration_state" => "sealed")
end
