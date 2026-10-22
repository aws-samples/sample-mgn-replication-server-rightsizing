terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.target_account_id]
}

module "automation_role" {
  source = "../modules/automation-role"

  aws_region           = var.aws_region
  target_account_id    = var.target_account_id
  automation_role_name = var.automation_role_name
  lambda_role_arn      = var.lambda_role_arn
  tags                 = var.tags
}
