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

locals {
  # Fixed STS session name. The execution-role policy only allows AssumeRole
  # with this name, and it identifies the automation in target-account CloudTrail.
  assume_role_session_name = "MgnReplicationAutoscaler"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../../../src/replication_autoscaler.py"
  # path.root always exists on a clean checkout; generated ZIPs are git-ignored.
  output_path = "${path.root}/${var.name_prefix}.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.name_prefix}-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Required for cross-account access. Scoped to one exact role ARN and
        # one fixed session name. The function requests the minimum 15-minute
        # session, keeps the temporary credentials in memory only, and never
        # logs or returns them. sts:AssumeRole is the AWS-recommended mechanism
        # for cross-account access; no long-term credentials are issued.
        Sid      = "AssumeConfiguredTargetRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = var.automation_role_arn
        Condition = {
          StringEquals = { "sts:RoleSessionName" = local.assume_role_session_name }
        }
      },
      {
        Sid      = "WriteFunctionLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_dlq" {
  # count must be known at plan time, so it keys off a boolean rather than the
  # queue ARN (which is unknown until the queue is created).
  count = var.enable_dead_letter_queue ? 1 : 0
  name  = "${var.name_prefix}-dlq-policy"
  role  = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "SendFailedAsyncInvocations"
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = var.dead_letter_queue_arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  # Optional customer managed key. Its key policy must allow the CloudWatch
  # Logs service principal for this Region. Null uses CloudWatch Logs default encryption.
  kms_key_id = var.log_kms_key_arn != "" ? var.log_kms_key_arn : null
  tags       = var.tags
}

resource "aws_lambda_function" "autoscaler" {
  function_name                  = var.name_prefix
  filename                       = data.archive_file.lambda_zip.output_path
  source_code_hash               = data.archive_file.lambda_zip.output_base64sha256
  handler                        = "replication_autoscaler.handler"
  runtime                        = "python3.12"
  architectures                  = ["x86_64"]
  timeout                        = 300
  memory_size                    = 256
  reserved_concurrent_executions = 1
  role                           = aws_iam_role.lambda.arn
  tags                           = var.tags

  dynamic "dead_letter_config" {
    for_each = var.enable_dead_letter_queue ? [var.dead_letter_queue_arn] : []
    content {
      target_arn = dead_letter_config.value
    }
  }

  lifecycle {
    precondition {
      condition     = !var.enable_dead_letter_queue || can(regex("^arn:[^:]+:sqs:", var.dead_letter_queue_arn))
      error_message = "dead_letter_queue_arn must be an SQS queue ARN when enable_dead_letter_queue is true."
    }
  }

  environment {
    variables = {
      TARGET_ACCOUNT_ID        = var.target_account_id
      TARGET_AWS_REGION        = var.target_aws_region
      AUTOMATION_ROLE_ARN      = var.automation_role_arn
      ASSUME_ROLE_SESSION_NAME = local.assume_role_session_name
      BASELINE_INSTANCE_TYPES  = join(",", var.baseline_instance_types)
      SIZE_TIERS               = length(var.size_tiers) > 0 ? jsonencode([for tier in var.size_tiers : [tier.min_gib, tier.instance_type]]) : ""
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
    aws_iam_role_policy.lambda_dlq,
  ]
}
