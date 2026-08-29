mock_provider "aws" {
  override_during = plan

  override_data {
    target = data.aws_iam_policy_document.lambda_assume_role
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.bluesky_oauth_runtime
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan
}

run "bluesky_oauth_runtime" {
  command = plan

  plan_options {
    target = [aws_lambda_function.bluesky_oauth]
  }

  assert {
    condition     = aws_lambda_function.bluesky_oauth.timeout == 30
    error_message = "Bluesky OAuth Lambda must allow enough time for OAuth discovery and token exchange"
  }

  assert {
    condition     = aws_lambda_function.bluesky_oauth.environment[0].variables.BLUESKY_OAUTH_SECRET_ID == aws_secretsmanager_secret.bluesky_oauth.name
    error_message = "Bluesky OAuth Lambda must receive its dedicated secret name"
  }
}
