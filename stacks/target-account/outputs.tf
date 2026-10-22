output "automation_role_arn" {
  description = "Target-account role ARN assumed by the autoscaler Lambda."
  value       = module.automation_role.automation_role_arn
}
