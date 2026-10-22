output "lambda_function_name" {
  description = "Name of the deployed auto-scaler Lambda."
  value       = module.autoscaler.lambda_function_name
}

output "lambda_function_arn" {
  description = "ARN of the deployed auto-scaler Lambda."
  value       = module.autoscaler.lambda_function_arn
}

output "lambda_role_arn" {
  description = "Lambda execution role ARN (grant sts:AssumeRole into the target-account automation role)."
  value       = module.autoscaler.lambda_role_arn
}

output "target_automation_role_arn" {
  description = "Target-account role ARN expected by this deployment."
  value       = local.automation_role_arn
}

output "schedule_rule_name" {
  description = "EventBridge schedule rule name (empty if scheduling is disabled)."
  value       = var.enable_schedule ? module.schedule[0].rule_name : ""
}

output "event_dlq_url" {
  description = "Schedule dead-letter queue URL (empty if scheduling is disabled)."
  value       = var.enable_schedule ? module.schedule[0].dead_letter_queue_url : ""
}
