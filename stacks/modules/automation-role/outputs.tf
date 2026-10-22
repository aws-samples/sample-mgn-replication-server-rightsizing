output "automation_role_arn" {
  description = "Target-account role ARN assumed by the autoscaler Lambda."
  value       = aws_iam_role.automation.arn
}
