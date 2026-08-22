resource "aws_apigatewayv2_api" "authoring" {
  name          = "weblog-authoring-production"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "authoring" {
  api_id                 = aws_apigatewayv2_api.authoring.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.authoring.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "authoring" {
  for_each = {
    "GET /health"             = "NONE"
    "GET /api/pages"          = "AWS_IAM"
    "GET /api/pages/{id}"     = "AWS_IAM"
    "GET /api/routes/{route}" = "AWS_IAM"
  }

  api_id             = aws_apigatewayv2_api.authoring.id
  route_key          = each.key
  authorization_type = each.value
  target             = "integrations/${aws_apigatewayv2_integration.authoring.id}"
}

resource "aws_cloudwatch_log_group" "authoring_api" {
  name              = "/aws/apigateway/weblog-authoring-production"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "authoring" {
  api_id      = aws_apigatewayv2_api.authoring.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.authoring_api.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      requestMethod    = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "authoring_api" {
  statement_id  = "AllowAuthoringApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authoring.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.authoring.execution_arn}/*/*"
}
