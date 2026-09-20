# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class ValidationWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW_PATH = File.join(ROOT, ".github/workflows/validation.yml")
  WORKFLOW = YAML.safe_load_file(WORKFLOW_PATH, aliases: true)

  def test_runs_only_for_main_pushes_with_read_only_permissions
    assert_equal({ "push" => { "branches" => ["main"] } }, WORKFLOW.fetch("on"))
    assert_equal({ "contents" => "read" }, WORKFLOW.fetch("permissions"))
  end

  def test_portable_job_uses_the_shared_check_and_uploads_sha_artifact
    job = WORKFLOW.fetch("jobs").fetch("portable")
    run_steps = job.fetch("steps").filter_map { |step| step["run"] }
    upload = job.fetch("steps").find { |step| step["uses"]&.start_with?("actions/upload-artifact@") }

    assert_equal "ubuntu-latest", job.fetch("runs-on")
    assert_includes run_steps, "mise run setup"
    assert_includes run_steps, "mise run check:portable"
    refute(run_steps.any? { |command| command.include?("npm run build") })
    assert_equal "site-${{ github.sha }}", upload.fetch("with").fetch("name")
    assert_equal "dist/site", upload.fetch("with").fetch("path")
    assert_equal 7, upload.fetch("with").fetch("retention-days")
  end

  def test_ios_checks_are_owned_by_xcode_cloud
    jobs = WORKFLOW.fetch("jobs")
    refute jobs.key?("ios")
    refute jobs.key?("changes")
    refute_includes File.read(WORKFLOW_PATH), "mise run check:ios"
  end

  def test_actions_are_pinned_and_workflow_has_no_production_credentials
    action_references = WORKFLOW.fetch("jobs").values.flat_map do |job|
      job.fetch("steps").filter_map { |step| step["uses"] }
    end
    source = File.read(WORKFLOW_PATH)

    assert(action_references.all? { |reference| reference.match?(/@[0-9a-f]{40}\z/) })
    refute_match(/aws-actions|mairu|id-token|secrets:/, source)
  end
end
