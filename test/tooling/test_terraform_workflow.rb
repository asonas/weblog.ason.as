# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class TerraformWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/terraform.yml"))
    @job = @workflow.dig("jobs", "apply")
    @steps = @job.fetch("steps")
  end

  def test_is_manual_main_only_and_does_not_cancel_an_apply
    assert_equal({}, @workflow.fetch("on").fetch("workflow_dispatch"))
    assert_equal "github.ref == 'refs/heads/main'", @job.fetch("if")
    assert_equal false, @workflow.dig("concurrency", "cancel-in-progress")
  end

  def test_shared_quality_check_precedes_credentials_and_plans
    quality = index_of("Run Terraform quality checks")
    credentials = @steps.index { |step| step["uses"]&.start_with?("aws-actions/configure-aws-credentials@") }
    first_plan = @steps.index { |step| step["run"]&.include?("terraform -chdir=infra/production plan") }
    assert_equal "mise run terraform:check", @steps.fetch(quality).fetch("run")
    assert_operator quality, :<, credentials
    assert_operator quality, :<, first_plan
  end

  def test_every_apply_consumes_a_saved_plan
    apply_commands = @steps.filter_map { |step| step["run"] }.select do |command|
      command.include?("terraform -chdir=infra/production apply")
    end
    refute_empty apply_commands
    apply_commands.each do |command|
      assert_match(/\b(?:search-bootstrap|inbox-bootstrap|oauth-bootstrap|production)\.tfplan\b/, command)
      refute_includes command, "-target="
    end
  end

  def test_bootstrap_repository_and_image_path_is_preserved
    source = File.read(File.join(ROOT, ".github/workflows/terraform.yml"))
    %w[search-indexer inbox-sync bluesky-oauth].each do |name|
      assert_includes source, "Dockerfile.#{name}"
    end
    assert_includes source, "ImageNotFoundException"
    assert_includes source, "RepositoryNotFoundException"
  end

  def test_actions_are_pinned
    actions = @steps.filter_map { |step| step["uses"] }
    assert(actions.all? { |action| action.match?(/@[0-9a-f]{40}\z/) })
  end

  private

  def index_of(name)
    @steps.index { |step| step["name"] == name }
  end
end
