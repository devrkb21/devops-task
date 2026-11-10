output "state_bucket" {
  description = "Put this in terraform/app/environments/*.s3.tfbackend as `bucket`."
  value       = aws_s3_bucket.state.bucket
}

output "ecr_repository_url" {
  description = "Image repository the CI pipeline pushes to."
  value       = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  description = "Set as the GitHub repository variable AWS_ROLE_ARN."
  value       = aws_iam_role.github_actions.arn
}

output "aws_region" {
  description = "Set as the GitHub repository variable AWS_REGION."
  value       = var.aws_region
}
