resource "aws_ecr_repository" "proofreading" {
  name                 = "weblog-proofreading-production"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "proofreading" {
  repository = aws_ecr_repository.proofreading.name
  policy = jsonencode({ rules = [{
    rulePriority = 1
    description  = "Keep the latest ten images"
    selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
    action       = { type = "expire" }
  }] })
}

resource "aws_iam_role" "proofreading_runtime" {
  name               = "weblog-proofreading-production-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "proofreading_basic_execution" {
  role       = aws_iam_role.proofreading_runtime.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "proofreading" {
  name              = "/weblog/lambda/proofreading-production"
  retention_in_days = 14
}

resource "aws_lambda_function" "proofreading" {
  function_name                  = "weblog-proofreading-production"
  package_type                   = "Image"
  image_uri                      = "${aws_ecr_repository.proofreading.repository_url}:bootstrap"
  role                           = aws_iam_role.proofreading_runtime.arn
  architectures                  = ["arm64"]
  memory_size                    = 1024
  timeout                        = 20
  reserved_concurrent_executions = 2

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.proofreading.name
  }
  depends_on = [aws_iam_role_policy_attachment.proofreading_basic_execution]
  lifecycle {
    ignore_changes = [image_uri]
  }
}

data "aws_iam_policy_document" "invoke_proofreading" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.proofreading.arn]
  }
}

resource "aws_iam_role_policy" "invoke_proofreading" {
  name   = "InvokeProofreading"
  role   = aws_iam_role.authoring_runtime.id
  policy = data.aws_iam_policy_document.invoke_proofreading.json
}

resource "aws_apigatewayv2_route" "proofreading" {
  api_id             = aws_apigatewayv2_api.authoring.id
  route_key          = "POST /api/authoring/proofread"
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.authoring.id}"
}
