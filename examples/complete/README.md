# Complete deployment example

This example deploys the entire solution with a single `terraform apply`:

- **Deployment account:** the auto-scaler Lambda function, its execution role, CloudWatch Logs log group, EventBridge schedule, and encrypted SQS dead-letter queue.
- **Target account:** the IAM automation role that the Lambda assumes, with exact trust for the Lambda execution role and least-privilege AWS Transform MGN permissions.

The deployment and target accounts can be different accounts or the same account. Terraform uses two AWS provider configurations, and each one refuses to run with credentials for any account other than the one you configure.

The schedule is enabled by default in **report-only mode** (`auto_update = false`). Scheduled runs log their decisions but make no changes until you opt in.

## Prerequisites

- AWS Transform MGN initialized in the target AWS Region, with source servers registered.
- Terraform 1.3 or later and AWS CLI v2.
- Credentials for the deployment account that can create Lambda, IAM, CloudWatch Logs, EventBridge, and Amazon SQS resources.
- Credentials for the target account that can create an IAM role and inline policy.

## Configure credentials

Choose the option that matches your environment:

| Scenario | Configuration |
|---|---|
| Single account | Leave all credential variables unset; the default credential chain is used for both providers. |
| Separate named profiles | Set `deployment_profile` and `target_profile`. |
| Cross-account deployment role | Set `target_assume_role_arn` to a role in the target account that your deployment credentials can assume. |

## Deploy

Clone the repository and run these commands from the repository root:

```bash
git clone https://github.com/aws-samples/sample-mgn-replication-server-rightsizing.git
cd sample-mgn-replication-server-rightsizing
```

Then configure and deploy:

```bash
cp examples/complete/terraform.tfvars.example examples/complete/terraform.tfvars
# Set deployment_account_id, target_account_id, and credential settings.

terraform -chdir=examples/complete init
terraform -chdir=examples/complete plan -out=deploy.tfplan
terraform -chdir=examples/complete apply deploy.tfplan
rm examples/complete/deploy.tfplan
```

Terraform creates the Lambda execution role first, then the target-account role that trusts it, and creates the schedule only after the target role exists.

## Validate with a dry-run

```bash
FUNCTION_NAME=$(terraform -chdir=examples/complete output -raw lambda_function_name)

aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --payload fileb://events/dry-run.json \
  --cli-binary-format raw-in-base64-out \
  response.json
python3 -m json.tool response.json
```

For each server, review `source_capacity_gib`, `inventory_complete`, `target_instance`, `should_update`, and `decision_reason`. Delete `response.json` when you are done; it contains source-server hostnames and identifiers.

## Enable updates

Changing a replication server instance type restarts that replication server and can cause a brief resynchronization. Apply changes early in a migration wave, not near cutover.

To apply the reviewed changes once:

```bash
aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --payload fileb://events/apply.json \
  --cli-binary-format raw-in-base64-out \
  response.json
```

To let scheduled runs apply updates, set `auto_update = true` in `terraform.tfvars` and run `terraform apply` again.

## Monitor

- **Logs:** CloudWatch Logs group `/aws/lambda/<name_prefix>`.
- **Failures:** messages in the queue from `terraform output -raw dead_letter_queue_url`. Each message represents an invocation that failed after retries. Inspect the logs before replaying it.
- **Audit:** AWS CloudTrail `UpdateReplicationConfiguration` events in the target account.

## Clean up

1. Set `enable_schedule = false` and run `terraform apply` to stop scheduled invocations.
2. If required, restore each source server's intended replication instance type. Destroying this example does not revert AWS Transform MGN replication settings.
3. Destroy the example:

```bash
terraform -chdir=examples/complete destroy
```

## Inputs

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `deployment_account_id` | Yes | — | Account for the Lambda, schedule, and dead-letter queue |
| `target_account_id` | Yes | — | Account containing AWS Transform MGN source servers |
| `aws_region` | No | `us-east-1` | AWS Transform MGN Region; the Lambda is deployed in the same Region |
| `deployment_profile` | No | `null` | AWS CLI profile for the deployment account |
| `target_profile` | No | `null` | AWS CLI profile for the target account |
| `target_assume_role_arn` | No | `""` | Role that Terraform assumes in the target account |
| `name_prefix` | No | `mgn-replication-autoscaler` | Lambda name and resource prefix (1-59 characters) |
| `automation_role_name` | No | `MGNReplicationAutoScalerRole` | Target-account role name |
| `size_tiers` | No | Built-in ladder | List of `{ min_gib, instance_type }` |
| `enable_schedule` | No | `true` | Create the EventBridge schedule and dead-letter queue |
| `schedule_expression` | No | `rate(6 hours)` | Schedule cadence |
| `auto_update` | No | `false` | Scheduled runs apply updates (`true`) or report only (`false`) |
| `log_retention_days` | No | `365` | CloudWatch Logs retention |
| `log_kms_key_arn` | No | `""` | Customer managed KMS key for the log group |
| `tags` | No | `{}` | Tags applied to all supported resources in both accounts |

## Outputs

| Output | Description |
|---|---|
| `lambda_function_name` | Lambda function name for manual invocations |
| `lambda_function_arn` | Lambda function ARN |
| `lambda_role_arn` | Lambda execution role ARN |
| `automation_role_arn` | Target-account role ARN assumed by the Lambda |
| `schedule_rule_name` | EventBridge rule name (empty if disabled) |
| `dead_letter_queue_url` | Dead-letter queue URL (empty if disabled) |

## State

This example uses local state by default. For shared or production use, add an encrypted, access-controlled remote backend with state locking before running `terraform init`. Do not commit `terraform.tfvars`, state files, or plan files.
