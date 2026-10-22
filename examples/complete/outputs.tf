output "lambda_function_name" {
  description = "Name of the deployed auto-scaler Lambda."
  value       = module.autoscaler.lambda_function_name
}

output "lambda_function_arn" {
  description = "ARN of the deployed auto-scaler Lambda."
  value       = module.autoscaler.lambda_function_arn
}

output "lambda_role_arn" {
  description = "Lambda execution role ARN trusted by the target-account automation role."
  value       = module.autoscaler.lambda_role_arn
}

output "automation_role_arn" {
  description = "Target-account role ARN assumed by the Lambda."
  value       = module.automation_role.automation_role_arn
}

output "schedule_rule_name" {
  description = "EventBridge schedule rule name (empty if scheduling is disabled)."
  value       = var.enable_schedule ? module.schedule[0].rule_name : ""
}

output "dead_letter_queue_url" {
  description = "Dead-letter queue URL (empty if scheduling is disabled)."
  value       = var.enable_schedule ? module.schedule[0].dead_letter_queue_url : ""
}
