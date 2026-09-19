# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"
require "weblog_authoring/draft_store"
require "open3"

class DraftCheckpointsTest < Minitest::Test
  ID = "dc802ad0-b899-46ae-b6b7-623c2ba7bc79"
  SCOPE = { "protocol" => 1, "generation" => 1 }.freeze

  def setup
    @root = Pathname(Dir.mktmpdir("draft-checkpoints"))
    @path = @root.join("drafts.sqlite3")
    @store = WeblogAuthoring::DraftStore.sqlite(@path)
    @store.setup!
    @store.create(ID, SCOPE)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_activation_preserves_later_updates_and_original_retry_receipts
    first = append("first")
    job = @store.checkpoint_job(ID)
    assert_equal 1, job.fetch("through")
    assert_nil job.fetch("checkpoint")
    append("later")
    candidate = checkpoint(1, (0..255).to_a.pack("C*") * 1025)
    active = @store.activate_verified_checkpoint(ID, candidate, expected_checkpoint: job.fetch("expected_checkpoint"))
    assert_equal active, @store.activate_verified_checkpoint(ID, candidate, expected_checkpoint: 0)
    reopened = WeblogAuthoring::DraftStore.sqlite(@path).checkpoint_job(ID)
    assert_equal 2, reopened.fetch("through")
    assert_equal active, reopened.fetch("checkpoint")
    assert_equal candidate.fetch("data"), active.fetch("data")
    assert_equal first, append("first")
    assert_equal 2, @store.read(ID, { "cursor" => "1" }).fetch("updates").first.fetch("sequence")
    initial = @store.read(ID, {})
    assert_empty initial.fetch("updates")
    assert_equal 1, initial.dig("checkpoint", "through")
  end

  def test_persisted_updates_are_verified_by_javascript_before_activation
    history = worker("history")
    history.each_with_index { |update, index| @store.append(ID, SCOPE.merge(update).merge("update_id" => "real-#{index}", "body_bytes" => 12)) }
    job = @store.checkpoint_job(ID)
    updates = []
    cursor = 0
    while cursor < job.fetch("through")
      page = @store.read(ID, { "cursor" => cursor.to_s, "through" => job.fetch("through").to_s })
      updates.concat(page.fetch("updates"))
      cursor = page.fetch("cursor")
    end
    verified = worker("verify", job.merge("updates" => updates))
    assert_equal "残す", verified.fetch("markdown")
    active = @store.activate_verified_checkpoint(ID, verified, expected_checkpoint: job.fetch("expected_checkpoint"))
    resumed = worker("verify", @store.checkpoint_job(ID).merge("updates" => []))
    assert_equal "残す", resumed.fetch("markdown")
    assert_equal active.fetch("digest"), resumed.fetch("digest")
  end

  def test_stale_worker_cannot_replace_newer_checkpoint_or_mutate_same_sequence
    append("one")
    append("two")
    @store.activate_verified_checkpoint(ID, checkpoint(1), expected_checkpoint: 0)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @store.activate_verified_checkpoint(ID, checkpoint(2), expected_checkpoint: 0)
    }.status
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @store.activate_verified_checkpoint(ID, checkpoint(1, "different"), expected_checkpoint: 0)
    }.status
    assert_equal 1, @store.checkpoint_job(ID).fetch("expected_checkpoint")
    @store.activate_verified_checkpoint(ID, checkpoint(2), expected_checkpoint: 1)
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @store.activate_verified_checkpoint(ID, checkpoint(1), expected_checkpoint: 0)
    }.status
    assert_equal 2, @store.checkpoint_job(ID).fetch("expected_checkpoint")
  end

  def test_failed_storage_rolls_back_pointer_and_incomplete_checkpoint_is_not_read
    append("one")
    db = SQLite3::Database.new(@path.to_s)
    db.execute("CREATE TRIGGER reject_checkpoint BEFORE INSERT ON draft_checkpoint_chunks BEGIN SELECT RAISE(ABORT, 'storage failure'); END")
    assert_raises(SQLite3::ConstraintException) { @store.activate_verified_checkpoint(ID, checkpoint(1), expected_checkpoint: 0) }
    assert_nil @store.checkpoint_job(ID).fetch("checkpoint")
    db.execute("DROP TRIGGER reject_checkpoint")
    @store.activate_verified_checkpoint(ID, checkpoint(1), expected_checkpoint: 0)
    db.execute("DELETE FROM draft_checkpoint_chunks")
    assert_equal 503, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.checkpoint_job(ID) }.status
    assert_equal 503, assert_raises(WeblogAuthoring::DraftStore::Error) { @store.read(ID, {}) }.status
  ensure
    db&.close
  end

  def test_interrupted_staging_resumes_without_exposing_or_overwriting_partial_data
    append("one")
    candidate = checkpoint(1, "x" * (WeblogAuthoring::DraftStore::CHUNK_BYTES + 1))
    db = SQLite3::Database.new(@path.to_s)
    db.execute("CREATE TRIGGER interrupt_checkpoint BEFORE INSERT ON draft_checkpoint_chunks WHEN NEW.position = 1 BEGIN SELECT RAISE(ABORT, 'connection lost'); END")
    assert_raises(SQLite3::ConstraintException) { @store.activate_verified_checkpoint(ID, candidate, expected_checkpoint: 0) }
    assert_equal 1, db.get_first_value("SELECT count(*) FROM draft_checkpoint_chunks")
    assert_nil @store.checkpoint_job(ID).fetch("checkpoint")
    db.execute("DROP TRIGGER interrupt_checkpoint")
    assert_equal 409, assert_raises(WeblogAuthoring::DraftStore::Error) {
      @store.activate_verified_checkpoint(ID, checkpoint(1, "different"), expected_checkpoint: 0)
    }.status
    db.execute("CREATE TRIGGER reject_manifest BEFORE INSERT ON draft_checkpoints BEGIN SELECT RAISE(ABORT, 'manifest failure'); END")
    assert_raises(SQLite3::ConstraintException) { @store.activate_verified_checkpoint(ID, candidate, expected_checkpoint: 0) }
    assert_nil @store.checkpoint_job(ID).fetch("checkpoint")
    db.execute("DROP TRIGGER reject_manifest")
    active = @store.activate_verified_checkpoint(ID, candidate, expected_checkpoint: 0)
    assert_equal candidate.fetch("data"), active.fetch("data")
    assert_equal 2, db.get_first_value("SELECT count(*) FROM draft_checkpoint_chunks")
  ensure
    db&.close
  end

  def test_compaction_threshold_uses_only_uncompacted_updates_and_preserves_suffix
    history = worker("history")
    999.times { |index| @store.append(ID, SCOPE.merge(history.first).merge("update_id" => "count-#{index}", "body_bytes" => 12)) }
    assert_nil @store.compact(ID) { flunk "Worker must not run below threshold" }
    @store.append(ID, SCOPE.merge(history.last).merge("update_id" => "deletion", "body_bytes" => 6))
    active = @store.compact(ID) do |job|
      @store.append(ID, SCOPE.merge(history.first).merge("update_id" => "suffix", "body_bytes" => 6))
      worker("verify", job)
    end
    assert_equal 1000, active.fetch("through")
    assert_equal 1001, @store.checkpoint_job(ID).fetch("through")
    assert_nil @store.compact(ID) { flunk "Covered updates must not count again" }
    resumed = worker("verify", @store.checkpoint_job(ID).merge("updates" => @store.read(ID, { "cursor" => "1000" }).fetch("updates")))
    assert_equal "残す", resumed.fetch("markdown")
  end

  def test_local_command_compacts_at_byte_threshold_and_retries_without_changes
    output, error, status = Open3.capture3("node", "node_modules/tsx/dist/cli.mjs", "test/fixtures/drafts/reconstruct.mjs", "history", "large")
    assert status.success?, error
    history = JSON.parse(output)
    history.each_with_index { |update, index| @store.append(ID, SCOPE.merge(update).merge("update_id" => "large-#{index}", "body_bytes" => 400 * 1024)) }
    output, error, status = Open3.capture3(RbConfig.ruby, "bin/compact-local-draft", @path.to_s, ID)
    assert status.success?, error
    assert_equal 6, JSON.parse(output).fetch("through")
    active = @store.checkpoint_job(ID).fetch("checkpoint")
    resumed = worker("verify", @store.checkpoint_job(ID).merge("updates" => []))
    assert_equal "", resumed.fetch("markdown")
    output, error, status = Open3.capture3(RbConfig.ruby, "bin/compact-local-draft", @path.to_s, ID)
    assert status.success?, error
    assert_equal "Below compaction threshold", JSON.parse(output).fetch("skipped")
    assert_equal active, @store.checkpoint_job(ID).fetch("checkpoint")
  end

  def test_worker_failure_preserves_original_updates_without_activating_checkpoint
    binary = "invalid" * 160_000
    update = SCOPE.merge("update_id" => "corrupt", "data" => Base64.strict_encode64(binary), "digest" => Digest::SHA256.hexdigest(binary), "body_bytes" => 0)
    receipt = @store.append(ID, update)
    output, error, status = Open3.capture3(RbConfig.ruby, "bin/compact-local-draft", @path.to_s, ID)
    refute status.success?
    assert_empty output
    assert_includes error, "Checkpoint reconstruction failed"
    assert_nil @store.checkpoint_job(ID).fetch("checkpoint")
    assert_equal update.fetch("data"), @store.read(ID, {}).fetch("updates").first.fetch("data")
    assert_equal receipt, @store.append(ID, update)
  end

  def test_cleanup_removes_only_covered_payloads_after_seven_days
    first = append("one")
    activated = @store.activate_verified_checkpoint(ID, checkpoint(1), expected_checkpoint: 0)
    append("two")
    before = Time.iso8601(activated.fetch("activated_at")) + (7 * 24 * 60 * 60) - 1
    assert_equal 0, @store.cleanup_compacted(ID, now: before)
    assert_equal 1, @store.cleanup_compacted(ID, now: before + 2)
    assert_equal 0, @store.cleanup_compacted(ID, now: before + 2)
    assert_equal first, append("one")
    initial = @store.read(ID, {})
    assert_equal 1, initial.dig("checkpoint", "through")
    assert_equal 2, @store.read(ID, { "cursor" => "1" }).fetch("cursor")
  end

  def test_expired_fixed_range_requests_restart_from_the_current_checkpoint
    append("one")
    append("two")
    activated = @store.activate_verified_checkpoint(ID, checkpoint(2), expected_checkpoint: 0)
    after_retention = Time.iso8601(activated.fetch("activated_at")) + (7 * 24 * 60 * 60) + 1
    assert_equal 2, @store.cleanup_compacted(ID, now: after_retention)
    error = assert_raises(WeblogAuthoring::DraftStore::Error) { @store.read(ID, { "through" => "1" }) }
    assert_equal 410, error.status
    assert_equal 2, @store.read(ID, {}).dig("checkpoint", "through")
  end

  private

  def worker(action, input = {})
    output, error, status = Open3.capture3("node", "node_modules/tsx/dist/cli.mjs", "test/fixtures/drafts/reconstruct.mjs", action, stdin_data: JSON.generate(input))
    assert status.success?, error
    JSON.parse(output)
  end

  def append(update_id)
    @store.append(ID, SCOPE.merge("update_id" => update_id, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0))
  end

  def checkpoint(sequence, binary = "\0\0")
    SCOPE.merge("article_id" => ID, "through" => sequence, "data" => Base64.strict_encode64(binary), "digest" => Digest::SHA256.hexdigest(binary))
  end
end
