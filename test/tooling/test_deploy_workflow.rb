# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class DeployWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/deploy.yml"))
    @build_workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/build-lambda-image.yml"))
    @rollback_workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/rollback-lambda.yml"))
  end

  def test_only_current_successful_main_validation_can_deploy
    trigger = @workflow.fetch("on").fetch("workflow_run")
    assert_equal ["Validate"], trigger.fetch("workflows")
    assert_equal ["completed"], trigger.fetch("types")
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

  def test_mutations_publish_stable_entrypoints_before_targeted_invalidation
    steps = @workflow.dig("jobs", "deploy", "steps")
    names = steps.filter_map { |step| step["name"] }
    ordered = ["Apply database schema", "Deploy authoring Lambda image", "Publish immutable site assets", "Publish stable site assets", "Publish site HTML", "Invalidate CloudFront", "Smoke check production"]
    assert_equal(ordered, names.select { |name| ordered.include?(name) })
    assets = steps.find { |step| step["name"] == "Publish immutable site assets" }.fetch("run")
    assert_includes assets, "static/authoring/assets/"
    refute_includes assets, "--delete"
    assert_includes assets, "max-age=31536000,immutable"
    refute_includes assets, "s3://${SITE_BUCKET}/assets/"
    stable = steps.find { |step| step["name"] == "Publish stable site assets" }.fetch("run")
    assert_includes stable, "static/authoring/app.js"
    assert_includes stable, "static/authoring/app.css"
    assert_includes stable, "max-age=0,must-revalidate"
    refute(steps.any? { |step| step["run"]&.include?("--delete") })
    html = steps.find { |step| step["name"] == "Publish site HTML" }.fetch("run")
    assert_includes html, "max-age=0,must-revalidate"
    invalidation = steps.find { |step| step["name"] == "Invalidate CloudFront" }.fetch("run")
    assert_includes invalidation, "'/static/authoring/app.js' '/static/authoring/app.css' '/index.html'"
    refute_includes invalidation, "'/*'"
    assert_includes invalidation, "wait invalidation-completed"

    deploy_policy = File.read(File.join(ROOT, "infra/bootstrap/github_actions.tf"))
    assert_includes deploy_policy, '"cloudfront:CreateInvalidation"'
    assert_includes deploy_policy, '"cloudfront:GetInvalidation"'
  end

  def test_images_are_prepared_in_parallel_on_native_arm64
    build_jobs = @workflow.fetch("jobs").select { |name, _job| name.start_with?("build-") }
    assert_equal %w[build-authoring build-inbox build-oauth build-search], build_jobs.keys.sort
    build_jobs.each_value do |job|
      assert_equal ["gate"], Array(job.fetch("needs"))
      assert_equal "./.github/workflows/build-lambda-image.yml", job.fetch("uses")
    end

    build = @build_workflow.dig("jobs", "build")
    assert_equal "ubuntu-24.04-arm", build.fetch("runs-on")
    assert_equal true, build.dig("concurrency", "cancel-in-progress")
    steps = build.fetch("steps")
    refute(steps.any? { |step| step["uses"]&.include?("setup-qemu") })
    image = steps.find { |step| step["name"] == "Build and publish image" }
    assert_equal "linux/arm64", image.dig("with", "platforms")
    assert_equal "type=gha,scope=${{ inputs.service }}", image.dig("with", "cache-from")
    assert_equal "type=gha,mode=max,scope=${{ inputs.service }}", image.dig("with", "cache-to")
  end

  def test_images_are_reused_by_content_hash_and_deployed_by_digest
    steps = @build_workflow.dig("jobs", "build", "steps")
    inspect = steps.find { |step| step["name"] == "Inspect image inputs" }.fetch("run")
    assert_includes inspect, 'git ls-tree -r "$TARGET_SHA"'
    assert_includes inspect, 'image_tag="content-${content_hash}"'
    assert_includes inspect, "aws ecr batch-get-image"
    assert_includes inspect, 'git diff --quiet "$baseline_sha" "$TARGET_SHA"'
    %w[content_hash digest release_tag source_commit build_run_id].each do |output|
      assert @build_workflow.dig("on", "workflow_call", "outputs", output)
    end

    steps = @workflow.dig("jobs", "deploy", "steps")
    infrastructure = steps.find { |step| step["name"] == "Detect optional Lambda infrastructure" }.fetch("run")
    assert_includes infrastructure, "RepositoryNotFoundException"
    assert_includes infrastructure, "ResourceNotFoundException"
    assert_includes infrastructure, "exit 1"
    webmention_deploy = steps.find { |step| step["name"] == "Deploy Webmention Lambda image" }
    assert_includes webmention_deploy.fetch("if"), "needs.build-authoring.outputs.deploy == 'true'"
    assert_includes webmention_deploy.fetch("run"), "@${AUTHORING_DIGEST}"
    %w[receiver worker publisher cleanup].each do |service|
      assert_includes webmention_deploy.fetch("run"), "steps.infra.outputs.#{service}"
    end
    recheck = steps.find { |step| step["name"] == "Recheck current main before deployment" }
    schema = steps.find { |step| step["name"] == "Apply database schema" }
    assert_includes recheck.fetch("run"), "git/ref/heads/main"
    assert_equal "steps.current.outputs.current == 'true'", schema.fetch("if")
  end

  def test_new_images_receive_a_service_calver_tag
    steps = @build_workflow.dig("jobs", "build", "steps")
    inspect = steps.find { |step| step["name"] == "Inspect image inputs" }.fetch("run")
    image = steps.find { |step| step["name"] == "Build and publish image" }
    summary = steps.find { |step| step["name"] == "Summarize image preparation" }.fetch("run")

    assert_includes inspect, 'release_prefix="${SERVICE}.$(date -u +%F)."'
    assert_includes inspect, "aws ecr describe-images"
    assert_includes inspect, 'release_tag="${release_prefix}$((latest_build + 1))"'
    assert_includes image.dig("with", "tags"), ":${{ steps.inspect.outputs.release_tag }}"
    assert_includes summary, "Release tag:"

    deploy_policy = File.read(File.join(ROOT, "infra/bootstrap/github_actions.tf"))
    assert_includes deploy_policy, '"ecr:DescribeImages"'
  end

  def test_production_deploy_is_not_cancelled_and_records_the_five_minute_slo
    deploy = @workflow.dig("jobs", "deploy")
    assert_equal false, deploy.dig("concurrency", "cancel-in-progress")
    assert_equal 10, deploy.fetch("timeout-minutes")
    assert_equal %w[gate build-authoring build-search build-inbox build-oauth], deploy.fetch("needs")
    summary = deploy.fetch("steps").find { |step| step["name"] == "Summarize production deploy" }.fetch("run")
    assert_includes summary, "elapsed <= 300"
    assert_includes summary, "05m 00s"
    assert_includes summary, "Setup and schema"
    assert_includes summary, "Lambda deployment"
    assert_includes summary, "Site delivery and smoke check"
  end

  def test_successful_deploy_records_an_immutable_release_manifest
    steps = @workflow.dig("jobs", "deploy", "steps")
    names = steps.filter_map { |step| step["name"] }
    manifest = steps.find { |step| step["name"] == "Record deployment manifest" }
    script = manifest.fetch("run")

    assert_operator names.index("Smoke check production"), :<, names.index("Record deployment manifest")
    assert_includes script, "schema_version: 1"
    assert_includes script, "AUTHORING_RELEASE_TAG"
    assert_includes script, "AUTHORING_BUILD_RUN_ID"
    assert_includes script, 'deployments/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.json'
    assert_includes script, "deployments/latest.json"
    assert_includes script, "max-age=31536000,immutable"
    assert_includes script, "max-age=0,must-revalidate"
  end

  def test_actions_are_pinned
    actions = [@workflow, @build_workflow, @rollback_workflow].flat_map do |workflow|
      workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }.filter_map { |step| step["uses"] }
    end
    assert(actions.all? { |action| action.match?(/@[0-9a-f]{40}\z/) })
  end

  def test_lambda_rollback_requires_an_explicit_manifest_and_service
    trigger = @rollback_workflow.fetch("on").fetch("workflow_dispatch").fetch("inputs")
    assert_equal %w[deploy_run_id deploy_run_attempt service], trigger.keys
    assert_equal %w[authoring search-indexer inbox-sync bluesky-oauth], trigger.dig("service", "options")

    rollback = @rollback_workflow.dig("jobs", "rollback")
    assert_equal "production-deploy", rollback.dig("concurrency", "group")
    assert_equal false, rollback.dig("concurrency", "cancel-in-progress")
    steps = rollback.fetch("steps")
    validate = steps.find { |step| step["name"] == "Validate rollback manifest" }.fetch("run")
    restore = steps.find { |step| step["name"] == "Restore Lambda image" }.fetch("run")
    assert_includes validate, 'deployments/${DEPLOY_RUN_ID}-${DEPLOY_RUN_ATTEMPT}.json'
    assert_includes validate, "aws ecr batch-get-image"
    assert_includes restore, "@${DIGEST}"
    assert_includes restore, "Code.ResolvedImageUri"

    deploy_policy = File.read(File.join(ROOT, "infra/bootstrap/github_actions.tf"))
    assert_includes deploy_policy, 'sid       = "ReadDeploymentManifests"'
    assert_includes deploy_policy, "/deployments/*"
  end
end
