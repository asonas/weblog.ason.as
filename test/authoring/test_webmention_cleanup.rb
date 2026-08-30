# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "weblog_authoring/webmention_cleanup"

class WebmentionCleanupTest < Minitest::Test
  class Database
    attr_reader :calls

    def initialize
      @calls = []
    end

    def cleanup_expired_webmentions(kind:, limit:, dry_run:)
      calls << { kind:, limit:, dry_run: }
      raise "database unavailable" if kind == "snapshots"

      { "kind" => kind, "matched" => 1, "deleted" => dry_run ? 0 : 1, "remaining" => 0 }
    end
  end

  def test_each_cleanup_kind_is_isolated_and_dry_run_is_forwarded
    database = Database.new
    results = WeblogAuthoring::WebmentionCleanup.new(
      database:, dry_run: true, limit: 25, logger: StringIO.new
    ).call

    assert_equal WeblogAuthoring::WebmentionCleanup::KINDS, (database.calls.map { |call| call.fetch(:kind) })
    assert(database.calls.all? { |call| call == { kind: call.fetch(:kind), limit: 25, dry_run: true } })
    assert_equal "RuntimeError", results.fetch(1).fetch("error")
  end
end
