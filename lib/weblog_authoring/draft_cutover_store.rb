# frozen_string_literal: true

module WeblogAuthoring
  module DraftCutoverStore
    def setup_cutover!
      @connect.call do |db|
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_cutover_state (id INTEGER PRIMARY KEY, phase TEXT NOT NULL, evidence TEXT NOT NULL, migration_fingerprint TEXT)")
        db.query("CREATE TABLE IF NOT EXISTS #{db.prefix}draft_cutover_operations (id TEXT PRIMARY KEY, kind TEXT NOT NULL, phase TEXT NOT NULL, started_at TEXT NOT NULL)")
        db.query("INSERT INTO #{db.prefix}draft_cutover_state (id, phase, evidence) VALUES (1, 'legacy', '{}') ON CONFLICT (id) DO NOTHING")
      end
    end

    def cutover_status
      @connect.call do |db|
        db.transaction do
          cutover_state(db).merge("operations" => db.query("SELECT * FROM #{db.prefix}draft_cutover_operations ORDER BY started_at, id"))
        end
      end
    end

    def with_cutover_operation(kind)
      raise DraftStore::Error, "Unknown cutover operation" unless %w[legacy_write draft_write publication legacy_publication draft_publication migration].include?(kind)
      token = SecureRandom.uuid
      phase = @connect.call do |db|
        db.transaction do
          current = cutover_state(db).fetch("phase")
          if kind == "legacy_write" && %w[open paused].include?(current)
            raise DraftStore::CutoverError.new("upgrade_required")
          end
          allowed = case kind
                    when "legacy_write" then current == "legacy"
                    when "draft_write" then current == "open"
                    when "publication" then %w[legacy draining preparing verifying open].include?(current)
                    when "legacy_publication" then %w[legacy draining].include?(current)
                    when "draft_publication" then %w[preparing verifying open].include?(current)
                    when "migration" then current == "frozen"
                    end
          raise DraftStore::CutoverError.new("authoring_maintenance") unless allowed
          db.query("UPDATE #{db.prefix}draft_cutover_state SET phase = phase WHERE id = 1")
          db.query("INSERT INTO #{db.prefix}draft_cutover_operations (id, kind, phase, started_at) VALUES ($1, $2, $3, $4)", [token, kind, current, Time.now.utc.iso8601(6)])
          current
        end
      end
      begin
        yield phase
      ensure
        @connect.call { |db| db.query("DELETE FROM #{db.prefix}draft_cutover_operations WHERE id = $1", [token]) }
      end
    end

    def transition_cutover(expected:, to:, evidence: {})
      @connect.call do |db|
        db.transaction do
          current = cutover_state(db)
          allowed = { "legacy" => ["draining"], "draining" => %w[frozen legacy], "frozen" => %w[preparing legacy], "preparing" => %w[verifying legacy],
                      "verifying" => %w[open legacy], "open" => ["paused"], "paused" => ["open"], }
          unless current.fetch("phase") == expected && allowed.fetch(expected, []).include?(to)
            raise DraftStore::Error.new("Cutover phase changed or transition is not allowed", 409)
          end
          if !%w[draining paused].include?(to) && db.query("SELECT id FROM #{db.prefix}draft_cutover_operations LIMIT 1").any?
            raise DraftStore::Error.new("Wait for in-flight operations; never discard their receipts", 409)
          end
          if to == "frozen"
            require_cutover_evidence(evidence, "legacy_writers_retired" => true, "legacy_generators_paused" => true, "pending_legacy_publications" => 0)
          elsif to == "legacy"
            require_cutover_evidence(evidence, "legacy_state_verified" => true)
          elsif %w[preparing verifying open].include?(to)
            migration = db.query("SELECT fingerprint, state FROM #{db.prefix}draft_migration_state WHERE id = 1").first
            fingerprint = to == "preparing" ? evidence["fingerprint"] : current["migration_fingerprint"]
            required_state = expected == "paused" ? "sealed" : "verified"
            unless migration && migration.fetch("state") == required_state && migration.fetch("fingerprint") == fingerprint
              raise DraftStore::Error.new("Verify the preserved migration input before changing reader or writer paths", 409)
            end
            if to == "preparing"
              require_cutover_evidence(evidence, "source_preserved" => true)
              db.query("UPDATE #{db.prefix}draft_cutover_state SET migration_fingerprint = $1 WHERE id = 1", [fingerprint])
            elsif to == "verifying"
              require_cutover_evidence(evidence, "published_outputs_ready" => true, "legacy_generators_paused" => true)
            else
              require_cutover_evidence(evidence, "reader_outputs_verified" => true, "legacy_generators_paused" => true)
              db.query("UPDATE #{db.prefix}draft_migration_state SET state = 'sealed' WHERE id = 1")
            end
          end
          db.query("UPDATE #{db.prefix}draft_cutover_state SET phase = $1, evidence = $2 WHERE id = 1", [to, JSON.generate(evidence)])
        end
      end
      cutover_status
    end

    private

    def cutover_state(db)
      row = db.query("SELECT * FROM #{db.prefix}draft_cutover_state WHERE id = 1").first
      raise DraftStore::Error.new("Cutover control is not initialized", 503) unless row
      row.merge("evidence" => JSON.parse(row.fetch("evidence")))
    end

    def require_cutover_evidence(evidence, required)
      unless evidence.is_a?(Hash) && evidence["record"].is_a?(String) && !evidence.fetch("record").strip.empty? && required.all? { |key, value| evidence[key] == value }
        raise DraftStore::Error.new("Record verified operational evidence before transitioning", 409)
      end
    end
  end
end
