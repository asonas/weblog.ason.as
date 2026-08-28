mock_provider "aws" {
  override_during = plan

  override_data {
    target = data.aws_iam_policy_document.lambda_assume_role
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.inbox_sync_runtime
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan
}

run "inbox_sync_runtime" {
  command = plan

  plan_options {
    target = [
      aws_lambda_function.inbox_sync,
      aws_cloudwatch_event_rule.inbox_sync,
    ]
  }

  assert {
    condition     = aws_lambda_function.inbox_sync.timeout == 300
    error_message = "inbox sync Lambda must have a five minute timeout"
  }

  assert {
    condition     = aws_lambda_function.inbox_sync.reserved_concurrent_executions == 1
    error_message = "inbox sync Lambda must run one invocation at a time"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.inbox_sync.schedule_expression == "rate(1 hour)"
    error_message = "inbox sources must be synchronized hourly"
  }
}
