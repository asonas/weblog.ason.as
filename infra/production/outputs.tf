output "dsql_cluster_arn" {
  description = "ARN of the production Aurora DSQL cluster."
  value       = aws_dsql_cluster.weblog.arn
}

output "dsql_cluster_id" {
  description = "ID of the production Aurora DSQL cluster."
  value       = aws_dsql_cluster.weblog.identifier
}

output "authoring_runtime_role_arn" {
  description = "IAM role assumed by the production authoring Lambda."
  value       = aws_iam_role.authoring_runtime.arn
}

output "authoring_ecr_repository_url" {
  description = "ECR repository URL for the production authoring Lambda image."
  value       = aws_ecr_repository.authoring.repository_url
}

output "authoring_lambda_function_name" {
  description = "Name of the production authoring Lambda function."
  value       = aws_lambda_function.authoring.function_name
}

output "search_indexer_ecr_repository_url" {
  description = "ECR repository URL for the production search indexer Lambda image."
  value       = aws_ecr_repository.search_indexer.repository_url
}

output "search_indexer_lambda_function_name" {
  description = "Name of the production search indexer Lambda function."
  value       = aws_lambda_function.search_indexer.function_name
}

output "inbox_sync_runtime_role_arn" {
  description = "IAM role assumed by the production inbox sync Lambda."
  value       = aws_iam_role.inbox_sync_runtime.arn
}

output "inbox_sync_ecr_repository_url" {
  description = "ECR repository URL for the production inbox sync Lambda image."
  value       = aws_ecr_repository.inbox_sync.repository_url
}

output "inbox_sync_lambda_function_name" {
  description = "Name of the production inbox sync Lambda function."
  value       = aws_lambda_function.inbox_sync.function_name
}

output "bluesky_oauth_runtime_role_arn" {
  description = "IAM role assumed by the production Bluesky OAuth Lambda."
  value       = aws_iam_role.bluesky_oauth_runtime.arn
}

output "bluesky_oauth_ecr_repository_url" {
  description = "ECR repository URL for the production Bluesky OAuth Lambda image."
  value       = aws_ecr_repository.bluesky_oauth.repository_url
}

output "bluesky_oauth_lambda_function_name" {
  description = "Name of the production Bluesky OAuth Lambda function."
  value       = aws_lambda_function.bluesky_oauth.function_name
}

output "bluesky_oauth_secret_arn" {
  description = "ARN of the production Bluesky OAuth secret."
  value       = aws_secretsmanager_secret.bluesky_oauth.arn
}

output "authoring_api_endpoint" {
  description = "Endpoint of the production authoring API. Reads are public and mutations require an application session."
  value       = aws_apigatewayv2_api.authoring.api_endpoint
}

output "authoring_oauth_secret_arn" {
  description = "ARN of the Secrets Manager secret used by production GitHub OAuth."
  value       = aws_secretsmanager_secret.oauth.arn
}

output "site_bucket_name" {
  description = "Name of the private production site bucket."
  value       = aws_s3_bucket.site.id
}

output "cloudfront_distribution_id" {
  description = "ID of the production CloudFront distribution."
  value       = aws_cloudfront_distribution.weblog.id
}

output "cloudfront_domain_name" {
  description = "Domain name of the production CloudFront distribution."
  value       = aws_cloudfront_distribution.weblog.domain_name
}
