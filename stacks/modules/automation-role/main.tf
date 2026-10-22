terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.lambda_role_arn]
    }
  }
}

resource "aws_iam_role" "automation" {
  name               = var.automation_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.target_account_id
      error_message = "Active AWS credentials do not match target_account_id."
    }
  }
}

resource "aws_iam_role_policy" "automation" {
  name = "${var.automation_role_name}-policy"
  role = aws_iam_role.automation.id

  # These permissions match the validated AWS Transform MGN update flow used by
  # this sample. Review and further restrict them for your environment.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "MGNInventory"
        Effect   = "Allow"
        Action   = "mgn:DescribeSourceServers"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
      {
        Sid      = "MGNReadReplication"
        Effect   = "Allow"
        Action   = "mgn:GetReplicationConfiguration"
        Resource = "arn:${data.aws_partition.current.partition}:mgn:${var.aws_region}:${var.target_account_id}:source-server/*"
      },
      {
        Sid      = "MGNUpdateReplication"
        Effect   = "Allow"
        Action   = "mgn:UpdateReplicationConfiguration"
        Resource = "arn:${data.aws_partition.current.partition}:mgn:${var.aws_region}:${var.target_account_id}:source-server/*"
      },
      {
        Sid    = "EC2DescribeForMGNUpdate"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVolumes"
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
      {
        Sid      = "CreateMGNLaunchTemplate"
        Effect   = "Allow"
        Action   = "ec2:CreateLaunchTemplate"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${var.target_account_id}:launch-template/*"
        Condition = {
          Null = { "aws:RequestTag/AWSApplicationMigrationServiceManaged" = "false" }
        }
      },
      {
        Sid    = "ModifyMGNLaunchTemplates"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplateVersion",
          "ec2:ModifyLaunchTemplate",
          "ec2:DeleteLaunchTemplateVersions"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${var.target_account_id}:launch-template/*"
        Condition = {
          Null = { "aws:ResourceTag/AWSApplicationMigrationServiceManaged" = "false" }
        }
      }
    ]
  })
}
