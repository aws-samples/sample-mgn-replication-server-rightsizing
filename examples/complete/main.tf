# Complete deployment: the auto-scaler Lambda, its optional schedule and
# dead-letter queue, and the target-account automation role, in one apply.
#
# The deployment and target accounts can be the same account or different
# accounts. Each provider refuses to run with credentials for any other account.

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

# Deployment account: Lambda, IAM execution role, CloudWatch Logs, EventBridge, SQS.
provider "aws" {
  region              = var.aws_region
  profile             = var.deployment_profile
  allowed_account_ids = [var.deployment_account_id]

  default_tags {
    tags = local.tags
  }
}

# Target account: the IAM role that the Lambda assumes to call AWS Transform MGN.
provider "aws" {
  alias               = "target"
  region              = var.aws_region
  profile             = var.target_profile
  allowed_account_ids = [var.target_account_id]

  dynamic "assume_role" {
    for_each = var.target_assume_role_arn != "" ? [var.target_assume_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "${var.name_prefix}-deploy"
    }
  }

  default_tags {
    tags = local.tags
  }
}

data "aws_partition" "current" {}

locals {
  automation_role_arn = "arn:${data.aws_partition.current.partition}:iam::${var.target_account_id}:role/${var.automation_role_name}"
  tags = merge(var.tags, {
    Application = var.name_prefix
    ManagedBy   = "Terraform"
  })
}

module "autoscaler" {
  source = "../../stacks/modules/autoscaler"

  name_prefix              = var.name_prefix
  target_account_id        = var.target_account_id
  target_aws_region        = var.aws_region
  automation_role_arn      = local.automation_role_arn
  size_tiers               = var.size_tiers
  baseline_instance_types  = var.baseline_instance_types
  log_retention_days       = var.log_retention_days
  log_kms_key_arn          = var.log_kms_key_arn
  enable_dead_letter_queue = var.enable_schedule
  dead_letter_queue_arn    = var.enable_schedule ? module.schedule[0].dead_letter_queue_arn : ""
}

module "automation_role" {
  source = "../../stacks/modules/automation-role"
  providers = {
    aws = aws.target
  }

  aws_region           = var.aws_region
  target_account_id    = var.target_account_id
  automation_role_name = var.automation_role_name
  lambda_role_arn      = module.autoscaler.lambda_role_arn
}

module "schedule" {
  source = "../../stacks/modules/schedule"
  count  = var.enable_schedule ? 1 : 0

  name_prefix          = var.name_prefix
  schedule_expression  = var.schedule_expression
  auto_update          = var.auto_update
  target_account_id    = var.target_account_id
  target_aws_region    = var.aws_region
  lambda_function_arn  = module.autoscaler.lambda_function_arn
  lambda_function_name = module.autoscaler.lambda_function_name

  # Do not schedule invocations until the role the Lambda assumes exists.
  depends_on = [module.automation_role]
}
