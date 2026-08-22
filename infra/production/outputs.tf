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
