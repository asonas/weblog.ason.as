# frozen_string_literal: true

require "minitest/autorun"

class TerraformWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_github_actions_do_not_run_terraform
    workflows = Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}"))
    refute_empty workflows
    workflows.each do |workflow|
      source = File.read(workflow)
      refute_match(/\bterraform(?:\s+-chdir|\s+(?:init|plan|apply|test|validate|fmt))/, source, workflow)
      refute_match(/mise run terraform:/, source, workflow)
    end
  end
end
