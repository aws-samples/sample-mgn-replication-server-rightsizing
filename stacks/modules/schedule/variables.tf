variable "name_prefix" {
  description = "Prefix for the EventBridge rule and SQS dead-letter queue names."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,59}$", var.name_prefix))
    error_message = "name_prefix must be 1-59 characters using letters, numbers, hyphens, or underscores."
  }
}

variable "schedule_expression" {
  description = "EventBridge schedule expression, for example rate(6 hours)."
  type        = string
  default     = "rate(6 hours)"

  validation {
    condition     = can(regex("^(rate|cron)\\(.+\\)$", var.schedule_expression))
    error_message = "schedule_expression must be a rate(...) or cron(...) expression."
  }
}

variable "auto_update" {
  description = "Whether scheduled runs apply updates (true) or only report (false)."
  type        = bool
  default     = false
}

variable "target_account_id" {
  description = "Target account ID sent in the scheduled event. Must match the Lambda deployment."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.target_account_id))
    error_message = "target_account_id must be a 12-digit AWS account ID."
  }
}

variable "target_aws_region" {
  description = "Target AWS Region sent in the scheduled event. Must match the Lambda deployment."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.target_aws_region))
    error_message = "target_aws_region must be a valid AWS Region name."
  }
}

variable "lambda_function_arn" {
  description = "ARN of the auto-scaler Lambda function to invoke."
  type        = string
}

variable "lambda_function_name" {
  description = "Name of the auto-scaler Lambda function to invoke."
  type        = string
}

variable "tags" {
  description = "Tags applied to supported resources."
  type        = map(string)
  default     = {}
}
