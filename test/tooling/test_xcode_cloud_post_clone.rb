# frozen_string_literal: true

require_relative "../test_helper"

require "fileutils"
require "open3"
require "tmpdir"

class XcodeCloudPostCloneTest < Minitest::Test
  SCRIPT = File.expand_path("../../ios/PhotoInbox/ci_scripts/ci_post_clone.sh", __dir__)

  def test_installs_xcodegen_and_generates_the_project_in_the_primary_repository
    Dir.mktmpdir do |directory|
      repository = File.join(directory, "repository")
      fake_bin = File.join(directory, "bin")
      calls = File.join(directory, "calls")
      FileUtils.mkdir_p(File.join(repository, "ios/PhotoInbox"))
      FileUtils.mkdir_p(fake_bin)
      FileUtils.mkdir_p(calls)
      File.write(File.join(repository, "ios/PhotoInbox/project.yml"), "name: PhotoInbox\n")
      write_executable(File.join(fake_bin, "brew"), <<~SH)
        #!/bin/sh
        printf '%s\n' "$*" > "$CALLS_DIRECTORY/brew"
      SH
      write_executable(File.join(fake_bin, "xcodegen"), <<~SH)
        #!/bin/sh
        printf '%s\n' "$*" > "$CALLS_DIRECTORY/xcodegen"
        mkdir -p "$CI_PRIMARY_REPOSITORY_PATH/ios/PhotoInbox/PhotoInbox.xcodeproj"
      SH

      output, status = Open3.capture2e(
        {
          "CALLS_DIRECTORY" => calls,
          "CI_PRIMARY_REPOSITORY_PATH" => repository,
          "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
        },
        SCRIPT
      )

      assert status.success?, output
      assert_equal "install xcodegen\n", File.read(File.join(calls, "brew"))
      assert_equal(
        "generate --spec #{repository}/ios/PhotoInbox/project.yml --project #{repository}/ios/PhotoInbox\n",
        File.read(File.join(calls, "xcodegen"))
      )
      assert_path_exists File.join(repository, "ios/PhotoInbox/PhotoInbox.xcodeproj")
    end
  end

  private

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod(0o755, path)
  end
end
