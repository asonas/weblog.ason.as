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

resource "aws_apigatewayv2_integration" "bluesky_oauth" {
  api_id                 = aws_apigatewayv2_api.authoring.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.bluesky_oauth.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "webmention_receiver" {
  api_id                 = aws_apigatewayv2_api.authoring.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.webmention_receiver.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "webmention_receiver" {
  api_id             = aws_apigatewayv2_api.authoring.id
  route_key          = "POST /api/webmentions"
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.webmention_receiver.id}"
}

resource "aws_apigatewayv2_route" "bluesky_oauth" {
  for_each = toset([
    "GET /oauth/bluesky/client-metadata.json",
    "GET /oauth/bluesky/jwks.json",
  ])

  api_id             = aws_apigatewayv2_api.authoring.id
  route_key          = each.value
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.bluesky_oauth.id}"
}

resource "aws_apigatewayv2_route" "authoring" {
  for_each = {
    "GET /health"                                              = "NONE"
    "GET /api/auth/session"                                    = "NONE"
    "GET /api/auth/github"                                     = "NONE"
    "GET /api/auth/github/callback"                            = "NONE"
    "POST /api/auth/logout"                                    = "NONE"
    "GET /api/pages"                                           = "NONE"
    "GET /api/tags"                                            = "NONE"
    "GET /api/archive"                                         = "NONE"
    "GET /api/page-names"                                      = "NONE"
    "GET /api/search"                                          = "NONE"
    "GET /api/related"                                         = "NONE"
    "GET /api/embed"                                           = "NONE"
    "GET /api/editor/new"                                      = "NONE"
    "GET /api/pages/{id}"                                      = "NONE"
    "GET /api/routes/{route}"                                  = "NONE"
    "POST /api/authoring/pages"                                = "NONE"
    "POST /api/uploads"                                        = "NONE"
    "POST /api/mobile/pairings"                                = "NONE"
    "POST /api/mobile/pairings/exchange"                       = "NONE"
    "GET /api/mobile/devices"                                  = "NONE"
    "POST /api/mobile/uploads"                                 = "NONE"
    "POST /api/mobile/uploads/{upload_id}/complete"            = "NONE"
    "DELETE /api/mobile/devices/{device_id}"                   = "NONE"
    "GET /api/inbox"                                           = "NONE"
    "GET /api/webmentions"                                     = "NONE"
    "GET /api/inbox/sync/{run_id}"                             = "NONE"
    "POST /api/inbox/adopt"                                    = "NONE"
    "POST /api/inbox/sync"                                     = "NONE"
    "GET /api/inbox/sources/bluesky/status"                    = "NONE"
    "POST /api/inbox/sources/bluesky/connect"                  = "NONE"
    "POST /api/inbox/sources/bluesky/refresh"                  = "NONE"
    "GET /api/inbox/sources/bluesky/callback"                  = "NONE"
    "DELETE /api/inbox/sources/bluesky/connection"             = "NONE"
    "PATCH /api/authoring/pages/{id}"                          = "NONE"
    "PATCH /api/authoring/webmentions/{id}"                    = "NONE"
    "DELETE /api/authoring/webmentions/{id}"                   = "NONE"
    "POST /api/authoring/webmentions/{id}/reverify"            = "NONE"
    "POST /api/authoring/webmention-deliveries/{id}/retry"     = "NONE"
    "POST /api/authoring/webmention-dead-letters/{kind}/retry" = "NONE"
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
      requestId          = "$context.requestId"
      requestMethod      = "$context.httpMethod"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      integrationLatency = "$context.integrationLatency"
      integrationError   = "$context.integrationErrorMessage"
    })
  }

  route_settings {
    route_key              = aws_apigatewayv2_route.webmention_receiver.route_key
    throttling_burst_limit = 10
    throttling_rate_limit  = 2
  }
}

resource "aws_lambda_permission" "authoring_api" {
  statement_id  = "AllowAuthoringApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authoring.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.authoring.execution_arn}/*/*"
}

resource "aws_lambda_permission" "bluesky_oauth_api" {
  statement_id  = "AllowBlueskyOAuthApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bluesky_oauth.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.authoring.execution_arn}/*/GET/oauth/bluesky/*"
}

resource "aws_lambda_permission" "webmention_receiver_api" {
  statement_id  = "AllowWebmentionApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webmention_receiver.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.authoring.execution_arn}/*/POST/api/webmentions"
}
