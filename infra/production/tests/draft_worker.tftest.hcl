mock_provider "aws" {
  override_during = plan

  override_data {
    target = data.aws_iam_policy_document.lambda_assume_role
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.draft_worker_runtime
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan
}

run "draft_worker_runs_hourly" {
  command = plan

  plan_options {
    target = [aws_cloudwatch_event_target.draft_worker]
  }

  assert {
    condition     = aws_lambda_function.draft_worker.reserved_concurrent_executions == 1 && aws_lambda_function.draft_worker.timeout == 300
    error_message = "Draft compaction must run as one bounded five-minute worker"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.draft_worker.schedule_expression == "rate(1 hour)" && aws_cloudwatch_event_rule.draft_worker.state == "ENABLED"
    error_message = "Draft compaction must run hourly after migration"
  }
}
