variable "name_prefix" {
  description = "Name for the Lambda function and prefix for its IAM resources."
  type        = string
  default     = "mgn-replication-autoscaler"

  validation {
    # 59 characters keeps the derived "<name_prefix>-role" IAM role name within 64.
    condition     = can(regex("^[A-Za-z0-9_-]{1,59}$", var.name_prefix))
    error_message = "name_prefix must be 1-59 characters using letters, numbers, hyphens, or underscores."
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

variable "target_aws_region" {
  description = "AWS Region containing the AWS Transform MGN source servers."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.target_aws_region))
    error_message = "target_aws_region must be a valid AWS Region name."
  }
}

variable "automation_role_arn" {
  description = "Exact target-account role ARN the Lambda assumes."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:role/.+$", var.automation_role_arn))
    error_message = "automation_role_arn must be an IAM role ARN."
  }
}

variable "size_tiers" {
  description = "Optional size tiers as { min_gib, instance_type }. Empty uses the built-in ladder."
  type = list(object({
    min_gib       = number
    instance_type = string
  }))
  default = []

  validation {
    condition = (
      alltrue([for tier in var.size_tiers : tier.min_gib > 0 && can(regex("^[a-z0-9][a-z0-9-]*\\.[a-z0-9]+$", lower(tier.instance_type)))]) &&
      length(distinct([for tier in var.size_tiers : tier.min_gib])) == length(var.size_tiers) &&
      length(distinct([for tier in var.size_tiers : lower(tier.instance_type)])) == length(var.size_tiers)
    )
    error_message = "Each tier must have a positive unique min_gib and a unique exact EC2 instance type; wildcards are not supported."
  }
}

variable "baseline_instance_types" {
  description = "Exact current instance types that may be promoted into a configured tier."
  type        = list(string)
  default     = ["t3.small", "t3.medium", "t3.large"]

  validation {
    condition = (
      length(var.baseline_instance_types) > 0 &&
      alltrue([for instance_type in var.baseline_instance_types : can(regex("^[a-z0-9][a-z0-9-]*\\.[a-z0-9]+$", lower(instance_type)))]) &&
      length(distinct([for instance_type in var.baseline_instance_types : lower(instance_type)])) == length(var.baseline_instance_types)
    )
    error_message = "baseline_instance_types must contain unique exact EC2 instance types; wildcards are not supported."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period in days for the Lambda log group. Minimum 365 to retain at least one year of audit history."
  type        = number
  default     = 365

  validation {
    condition     = contains([365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a supported CloudWatch Logs retention value of at least 365 days."
  }
}

variable "tags" {
  description = "Tags applied to supported resources."
  type        = map(string)
  default     = {}
}

variable "enable_dead_letter_queue" {
  description = "Attach dead_letter_queue_arn as the Lambda asynchronous-invocation DLQ. Must be known at plan time."
  type        = bool
  default     = false
}

variable "dead_letter_queue_arn" {
  description = "SQS queue ARN for failed asynchronous Lambda invocations. Used only when enable_dead_letter_queue is true."
  type        = string
  default     = ""
}

variable "log_kms_key_arn" {
  description = "Optional KMS key ARN for encrypting the Lambda log group. Empty uses CloudWatch Logs default encryption."
  type        = string
  default     = ""

  validation {
    condition     = var.log_kms_key_arn == "" || can(regex("^arn:[^:]+:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.log_kms_key_arn))
    error_message = "log_kms_key_arn must be empty or a KMS key ARN."
  }
}
