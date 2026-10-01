# frozen_string_literal: true

require "pathname"
require "json"
require "sqlite3"
root = Pathname(__dir__).parent
$LOAD_PATH.unshift(root.join("lib").to_s)
require "weblog_authoring/development_diary_migration"
require "weblog_authoring/development_app"

apply = ARGV.delete("--apply")
abort "Usage: mise exec -- ruby scripts/migrate-development-diary-pieces.rb [--apply] ARTICLE_ID..." if ARGV.empty? || ARGV.any? { |argument| argument.start_with?("-") }
path = WeblogAuthoring::DevelopmentApp.shared_development_root(root).join("data/development/drafts.sqlite3")
abort "Development database does not exist" unless path.file?
store = WeblogAuthoring::DraftStore.sqlite(path, pieces_enabled: true)
migration = WeblogAuthoring::DevelopmentDiaryMigration.new(store:)
plans = ARGV.map { |id| migration.migrate(id) }
puts JSON.pretty_generate(plans)
if apply && plans.any? { |plan| plan.fetch("status") == "planned" }
  backup_path = path.sub_ext(".before-diary-pieces-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}.sqlite3")
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
  ARGV.each { |id| puts JSON.generate(migration.migrate(id, apply: true)) }
end
