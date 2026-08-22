resource "aws_lambda_function" "authoring" {
  function_name = "weblog-authoring-production"
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.authoring.repository_url}:bootstrap-1"
  role          = aws_iam_role.authoring_runtime.arn
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 15

  environment {
    variables = {
      DSQL_HOST = "${aws_dsql_cluster.weblog.identifier}.dsql.${var.aws_region}.on.aws"
    }
  }

  depends_on = [
    aws_iam_role_policy.dsql_connect,
    aws_iam_role_policy_attachment.lambda_basic_execution,
  ]
}
