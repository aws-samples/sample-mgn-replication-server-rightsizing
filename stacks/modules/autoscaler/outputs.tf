output "lambda_function_name" {
  description = "Name of the deployed auto-scaler Lambda."
  value       = aws_lambda_function.autoscaler.function_name
}

output "lambda_function_arn" {
  description = "ARN of the deployed auto-scaler Lambda (use as an EventBridge target)."
  value       = aws_lambda_function.autoscaler.arn
}

output "lambda_role_arn" {
  description = "Execution role ARN. Grant this principal sts:AssumeRole into the target-account automation role."
  value       = aws_iam_role.lambda.arn
}
