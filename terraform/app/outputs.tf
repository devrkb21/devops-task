output "instance_id" {
  description = "EC2 instance ID (used by SSM for deployments)."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IPv4 address of the instance."
  value       = aws_instance.app.public_ip
}

output "app_url" {
  description = "Health endpoint of the deployed application."
  value       = "http://${aws_instance.app.public_ip}:${var.app_port}/health"
}

output "log_group" {
  description = "CloudWatch Logs group with the container logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "ssm_session_command" {
  description = "Open a shell on the instance without SSH."
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}
