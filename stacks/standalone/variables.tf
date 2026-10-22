variable "aws_region" {
  description = "AWS Region containing the AWS Transform MGN source servers and receiving the Lambda deployment."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS Region name."
  }
}

variable "deployment_account_id" {
  description = "Twelve-digit AWS account ID in which the standalone Lambda and optional schedule are deployed."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.deployment_account_id))
    error_message = "deployment_account_id must be a 12-digit AWS account ID."
  }
}

variable "target_account_id" {
  description = "Twelve-digit AWS account ID containing the AWS Transform MGN source servers."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.target_account_id))
    error_message = "target_account_id must be a 12-digit AWS account ID."
  }
}

variable "name_prefix" {
  description = "Name for the Lambda function and prefix for related resources."
  type        = string
  default     = "mgn-replication-autoscaler"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,59}$", var.name_prefix))
    error_message = "name_prefix must be 1-59 characters using letters, numbers, hyphens, or underscores."
  }
}

variable "automation_role_name" {
  description = "Name of the target-account role the Lambda assumes (must match stacks/target-account)."
  type        = string
  default     = "MGNReplicationAutoScalerRole"

  # Matches the automation-role module, which creates the role without a path.
  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.automation_role_name))
    error_message = "automation_role_name must be a valid IAM role name of 1-64 characters."
  }
}

variable "size_tiers" {
  description = "Optional tiers as { min_gib, instance_type }. Empty uses the built-in ladder."
  type = list(object({
    min_gib       = number
    instance_type = string
  }))
  default = []
}

variable "baseline_instance_types" {
  description = "Exact current instance types that may be promoted into a configured tier."
  type        = list(string)
  default     = ["t3.small", "t3.medium", "t3.large"]
}

variable "enable_schedule" {
  description = "Create an EventBridge schedule that invokes the Lambda."
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "EventBridge schedule expression."
  type        = string
  default     = "rate(6 hours)"
}

variable "auto_update" {
  description = "Whether scheduled runs apply updates (true) or only report (false)."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period in days (minimum 365)."
  type        = number
  default     = 365

  validation {
    condition     = contains([365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a supported CloudWatch Logs retention value of at least 365 days."
  }
}

variable "log_kms_key_arn" {
  description = "Optional KMS key ARN for the Lambda log group. Empty uses CloudWatch Logs default encryption."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
