# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/draft_publication"

class TestLocalDependencies < Minitest::Test
  def test_resolves_dependencies_from_the_canonical_parent_checkout
    Dir.mktmpdir("local-dependencies") do |directory|
      root = Pathname(directory)
      dependency = root.join("node_modules/tsx/dist/cli.mjs")
      worktree = root.join(".worktrees/feature")
      FileUtils.mkdir_p(dependency.dirname)
      FileUtils.mkdir_p(worktree)
      dependency.write("")

      assert_equal dependency.to_s,
                   WeblogAuthoring::DraftPublication.resolve_local_dependency(
                     worktree,
                     "node_modules/tsx/dist/cli.mjs"
                   )
    end
  end
end
