data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "authoring_runtime" {
  name               = "weblog-authoring-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "dsql_connect" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = [aws_dsql_cluster.weblog.arn]
  }
}

resource "aws_iam_role_policy" "dsql_connect" {
  name   = "AuroraDSQLConnect"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.dsql_connect.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.authoring_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
