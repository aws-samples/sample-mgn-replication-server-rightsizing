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

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.deployment_account_id]
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
  source = "../modules/autoscaler"

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
  tags                     = local.tags
}

module "schedule" {
  source = "../modules/schedule"
  count  = var.enable_schedule ? 1 : 0

  name_prefix          = var.name_prefix
  schedule_expression  = var.schedule_expression
  auto_update          = var.auto_update
  target_account_id    = var.target_account_id
  target_aws_region    = var.aws_region
  lambda_function_arn  = module.autoscaler.lambda_function_arn
  lambda_function_name = module.autoscaler.lambda_function_name
  tags                 = local.tags
}
