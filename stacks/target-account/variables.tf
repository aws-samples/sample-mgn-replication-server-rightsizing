variable "aws_region" {
  description = "AWS Region containing the AWS Transform MGN source servers."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS Region name."
  }
}

variable "target_account_id" {
  description = "Expected 12-digit AWS account ID for the active target-account credentials."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.target_account_id))
    error_message = "target_account_id must be a 12-digit AWS account ID."
  }
}

variable "automation_role_name" {
  description = "Name of the role the autoscaler Lambda assumes."
  type        = string
  default     = "MGNReplicationAutoScalerRole"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.automation_role_name))
    error_message = "automation_role_name must be a valid IAM role name of 1-64 characters."
  }
}

variable "lambda_role_arn" {
  description = "Exact Lambda execution-role ARN output by the standalone stack."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:role/.+$", var.lambda_role_arn))
    error_message = "lambda_role_arn must be an IAM role ARN."
  }
}

variable "tags" {
  description = "Tags applied to the IAM role."
  type        = map(string)
  default     = {}
}
