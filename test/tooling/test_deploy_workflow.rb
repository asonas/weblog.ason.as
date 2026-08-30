# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class DeployWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/deploy.yml"))
  end

  def test_only_current_successful_main_validation_can_deploy
    trigger = @workflow.fetch("on").fetch("workflow_run")
    assert_equal ["Validate"], trigger.fetch("workflows")
    assert_equal ["completed"], trigger.fetch("types")
    assert_equal false, @workflow.dig("concurrency", "cancel-in-progress")
    gate = @workflow.dig("jobs", "gate")
    assert_includes gate.fetch("if"), "conclusion == 'success'"
    assert_includes gate.fetch("if"), "head_branch == 'main'"
    assert_includes gate.fetch("steps").first.fetch("run"), "git/ref/heads/main"
  end

  def test_deploy_verifies_and_reuses_the_validation_artifact
    steps = @workflow.dig("jobs", "deploy", "steps")
    checkout = steps.find { |step| step["uses"]&.start_with?("actions/checkout@") }
    download = steps.find { |step| step["uses"]&.start_with?("actions/download-artifact@") }
    verify = steps.find { |step| step["name"] == "Verify deployment inputs" }.fetch("run")
    assert_equal "${{ github.event.workflow_run.head_sha }}", checkout.dig("with", "ref")
    assert_equal "site-${{ github.event.workflow_run.head_sha }}", download.dig("with", "name")
    assert_equal "${{ github.event.workflow_run.id }}", download.dig("with", "run-id")
    assert_includes verify, "artifact-metadata.json"
    assert_includes verify, '[[ "$checkout_sha" == "$TARGET_SHA" ]]'
    assert_includes verify, '[[ "$artifact_sha" == "$TARGET_SHA" ]]'
    refute(steps.any? { |step| step["run"]&.match?(/npm run build(?:\s|$)/) })
  end

  def test_mutations_are_ordered_and_delete_is_prefix_scoped
    steps = @workflow.dig("jobs", "deploy", "steps")
    names = steps.filter_map { |step| step["name"] }
    ordered = ["Apply database schema", "Deploy authoring Lambda image", "Publish immutable site assets", "Publish site HTML", "Invalidate CloudFront", "Smoke check production", "Delete stale site assets"]
    assert_equal(ordered, names.select { |name| ordered.include?(name) })
    assets = steps.find { |step| step["name"] == "Publish immutable site assets" }.fetch("run")
    assert_includes assets, "static/authoring/assets/"
    refute_includes assets, "--delete"
    assert_includes assets, "max-age=31536000,immutable"
    refute_includes assets, "s3://${SITE_BUCKET}/assets/"
    cleanup = steps.find { |step| step["name"] == "Delete stale site assets" }.fetch("run")
    assert_includes cleanup, "static/authoring/assets/"
    assert_includes cleanup, "--delete"
    html = steps.find { |step| step["name"] == "Publish site HTML" }.fetch("run")
    assert_includes html, "max-age=0,must-revalidate"
    invalidation = steps.find { |step| step["name"] == "Invalidate CloudFront" }.fetch("run")
    assert_includes invalidation, "wait invalidation-completed"

    deploy_policy = File.read(File.join(ROOT, "infra/bootstrap/github_actions.tf"))
    assert_includes deploy_policy, '"cloudfront:CreateInvalidation"'
    assert_includes deploy_policy, '"cloudfront:GetInvalidation"'
  end

  def test_each_lambda_has_an_independent_baseline_and_main_is_rechecked
    steps = @workflow.dig("jobs", "deploy", "steps")
    infrastructure = steps.find { |step| step["name"] == "Detect optional Lambda infrastructure" }.fetch("run")
    assert_includes infrastructure, "RepositoryNotFoundException"
    assert_includes infrastructure, "ResourceNotFoundException"
    assert_includes infrastructure, "exit 1"
    baselines = steps.find { |step| step["name"] == "Inspect Lambda deployment baselines" }.fetch("run")
    %w[authoring search inbox oauth].each { |service| assert_includes baselines, "inspect #{service}" }
    recheck = steps.find { |step| step["name"] == "Recheck current main before deployment" }
    schema = steps.find { |step| step["name"] == "Apply database schema" }
    assert_includes recheck.fetch("run"), "git/ref/heads/main"
    assert_equal "steps.current.outputs.current == 'true'", schema.fetch("if")
  end

  def test_actions_are_pinned
    actions = @workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps") }.filter_map { |step| step["uses"] }
    assert(actions.all? { |action| action.match?(/@[0-9a-f]{40}\z/) })
  end
end
