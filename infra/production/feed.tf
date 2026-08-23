resource "aws_cloudwatch_event_rule" "rss_feed" {
  name                = "weblog-rss-feed-production"
  description         = "Regenerate weblog.ason.as/feed.xml"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "rss_feed" {
  rule      = aws_cloudwatch_event_rule.rss_feed.name
  target_id = "authoring-lambda"
  arn       = aws_lambda_function.authoring.arn
}

resource "aws_lambda_permission" "rss_feed" {
  statement_id  = "AllowEventBridgeRssFeed"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authoring.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rss_feed.arn
}
