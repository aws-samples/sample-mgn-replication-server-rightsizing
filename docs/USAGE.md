# AWS Transform MGN replication server right-sizing: deployment guide

Source: [aws-samples/sample-mgn-replication-server-rightsizing](https://github.com/aws-samples/sample-mgn-replication-server-rightsizing). Run commands from the repository root.

## Behavior and boundaries

The Lambda processes every non-archived AWS Transform MGN source server in one configured account and AWS Region. For each server it:

1. Sums provisioned source-disk capacity from `sourceProperties.disks[].bytes`.
2. Reads `replicationServerInstanceType` from `GetReplicationConfiguration`.
3. Selects the highest size tier met by the source capacity.
4. Reports the decision or applies a monotonic upgrade.

It does **not** use filesystem utilization or replication-progress bytes. It does not downgrade. Types outside the baseline and configured tier sets are unmanaged and left unchanged.

## Default tier policy

| Source capacity | Target |
|---|---|
| Below 3,072 GiB (3 TiB) | No change |
| 3,072 GiB ≤ capacity < 6,144 GiB | `m5.xlarge` |
| 6,144 GiB ≤ capacity < 10,240 GiB | `m5.2xlarge` |
| 10,240 GiB ≤ capacity < 14,336 GiB | `m5.4xlarge` |
| 14,336 GiB ≤ capacity < 20,480 GiB | `m5.8xlarge` |
| 20,480 GiB or more | `m5.12xlarge` |

`min_gib` is an inclusive lower bound. Each tier applies until the next tier's `min_gib`, so the configuration intentionally has no upper-bound field. For example, `min_gib = 3072` selects `m5.xlarge` until the 6,144 GiB tier begins.

AWS Transform MGN configuration uses exact EC2 instance types rather than family wildcards. AWS documents `t3.small` as the service default and `m5.large`, `m5.xlarge`, or larger as common scale-up choices, which is why this sample's built-in ladder uses `m5`. These are sample operational defaults, not a universal service recommendation. Verify EBS/network throughput, x86_64 compatibility, instance availability, quotas, and price for each AWS Region. For accounts using exact `m6i` or `m7i` starting types, configure `baseline_instance_types` and a matching exact `size_tiers` ladder together.

## Common prerequisites

- AWS Transform MGN initialized in the target AWS Region.
- Terraform 1.3 or later.
- Deployment-account permissions for Lambda, IAM, CloudWatch Logs, EventBridge, and SQS.
- Target-account IAM permissions to create or modify the automation role and trust policy.
- AWS CLI v2 for manual invocations and verification.
- Source servers already registered in AWS Transform MGN.

The Lambda uses only Python 3.12 standard-library modules and the `boto3`/`botocore` libraries included in the Lambda runtime. No layer is required.

## Safe two-phase deployment

The trigger starts disabled because the target-account role cannot trust the Lambda execution role until that role exists. The standalone provider also requires `deployment_account_id` and refuses to operate when the active credentials belong to another account.

### Phase 1: deploy Lambda with schedule disabled

```bash
cp stacks/standalone/terraform.tfvars.example stacks/standalone/terraform.tfvars
# Set deployment_account_id and target_account_id.
terraform -chdir=stacks/standalone init
terraform -chdir=stacks/standalone apply
terraform -chdir=stacks/standalone output -raw lambda_role_arn
```

### Phase 2: create or update target role

For a dedicated role, use target-account credentials:

```bash
cp stacks/target-account/terraform.tfvars.example stacks/target-account/terraform.tfvars
# Set target_account_id and lambda_role_arn to the Phase 1 output.
terraform -chdir=stacks/target-account init
terraform -chdir=stacks/target-account apply
```

For an existing automation role, update its trust policy to allow the exact Lambda execution-role ARN. In commercial AWS Regions, replace `<REGION>` and `<ACCOUNT_ID>` in `iam/automation-policy-commercial.json` before comparing permissions. In other partitions, use the partition-aware target stack as the reference.

### Phase 3: dry-run, then enable trigger

```bash
aws lambda invoke \
  --function-name mgn-replication-autoscaler \
  --payload fileb://events/dry-run.json \
  --cli-binary-format raw-in-base64-out \
  response.json
python3 -m json.tool response.json
```

After review, set `enable_schedule=true`; keep `auto_update=false` for scheduled dry-runs, then set it to `true` only after approval. Restrict `lambda:InvokeFunction` to approved operators and automation because any authorized invoker can request apply mode.

## Shared modules

### Autoscaler module

The deployment roots pass these values to `stacks/modules/autoscaler`.

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `name_prefix` | No | `mgn-replication-autoscaler` | Lambda name and IAM prefix (1-59 characters) |
| `target_account_id` | Yes | — | Fixed target account |
| `target_aws_region` | Yes | — | Fixed AWS Transform MGN Region |
| `automation_role_arn` | Yes | — | Exact assumed-role ARN |
| `size_tiers` | No | Built-in ladder | List of `{min_gib, instance_type}` using exact instance types |
| `baseline_instance_types` | No | `t3.small`, `t3.medium`, `t3.large` | Exact current types eligible for promotion into a tier |
| `log_retention_days` | No | `365` | CloudWatch Logs retention |
| `log_kms_key_arn` | No | `""` | Optional customer managed KMS key for the log group |
| `tags` | No | `{}` | Resource tags |
| `enable_dead_letter_queue` | No | `false` | Internal root-stack flag; attaches `dead_letter_queue_arn` |
| `dead_letter_queue_arn` | No | `""` | Internal root-stack input for failed asynchronous invocations |

The standalone root creates and passes its encrypted SQS queue automatically; users do not set the dead-letter inputs in root tfvars. The flag is a separate boolean so Terraform can plan the queue and Lambda in a single apply. If you set `log_kms_key_arn`, the key policy must allow the `logs.<region>.amazonaws.com` service principal. Malformed explicit tiers fail Terraform validation or Lambda initialization. Thresholds must be unique, and target instance-size suffixes must increase. The Lambda has reserved concurrency of one to prevent overlapping runs.

### Automation-role module

`stacks/modules/automation-role` is the single implementation of the target role, exact Lambda-role trust, and AWS Transform MGN/EC2 permissions. `stacks/target-account` and `examples/complete` consume it.

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `aws_region` | Yes | — | Region used in IAM resource and request conditions |
| `target_account_id` | Yes | — | Account used in scoped resource ARNs and the credential guard |
| `automation_role_name` | No | `MGNReplicationAutoScalerRole` | Role name |
| `lambda_role_arn` | Yes | — | Exact Lambda execution role trusted to assume the role |
| `tags` | No | `{}` | Role tags |

The module exports `automation_role_arn` and inherits the caller's AWS provider so each root retains its own `allowed_account_ids` protection.

### Schedule module

`stacks/modules/schedule` creates the EventBridge rule, the Lambda invoke permission scoped to that rule, a retry policy, and an SSE-SQS dead-letter queue that denies non-TLS requests. The queue receives both EventBridge delivery failures and Lambda asynchronous execution failures. `stacks/standalone` and `examples/complete` consume it when `enable_schedule = true`.

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `name_prefix` | Yes | — | Rule and queue name prefix |
| `schedule_expression` | No | `rate(6 hours)` | `rate(...)` or `cron(...)` expression |
| `auto_update` | No | `false` | Value sent in the scheduled event |
| `target_account_id` | Yes | — | Account sent in the scheduled event |
| `target_aws_region` | Yes | — | Region sent in the scheduled event |
| `lambda_function_arn` | Yes | — | Function to invoke |
| `lambda_function_name` | Yes | — | Function granted the EventBridge invoke permission |
| `tags` | No | `{}` | Resource tags |

## Complete example

`examples/complete` deploys the Lambda stack and the target-account role in a single apply using two AWS provider configurations. See [`examples/complete/README.md`](../examples/complete/README.md).

## Standalone variables

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `aws_region` | No | `us-east-1` | Lambda and target AWS Transform MGN Region |
| `deployment_account_id` | Yes | — | Expected account for automation-stack credentials |
| `target_account_id` | Yes | — | AWS Transform MGN target account |
| `automation_role_name` | No | `MGNReplicationAutoScalerRole` | Target role name |
| `name_prefix` | No | `mgn-replication-autoscaler` | Resource name prefix |
| `size_tiers` | No | Built-in ladder | Capacity tiers using exact instance types |
| `baseline_instance_types` | No | `t3.small`, `t3.medium`, `t3.large` | Exact current types eligible for promotion into a tier |
| `enable_schedule` | No | `false` | Create schedule, retries, and DLQ |
| `schedule_expression` | No | `rate(6 hours)` | Schedule cadence |
| `auto_update` | No | `false` | Apply updates or report only |
| `log_retention_days` | No | `365` | Log retention |
| `log_kms_key_arn` | No | `""` | Optional customer managed KMS key for the log group |
| `tags` | No | `{}` | Additional tags |

The scheduled target sends a fixed account/Region event. The Lambda rejects event values that differ from its deployment configuration.

## Target-account role

`stacks/target-account` creates a dedicated role with exact trust for the Lambda role.

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `aws_region` | No | `us-east-1` | AWS Transform MGN Region and IAM policy resource scope |
| `target_account_id` | Yes | — | Expected account for active credentials; provider refuses mismatches |
| `automation_role_name` | No | `MGNReplicationAutoScalerRole` | Role to create |
| `lambda_role_arn` | Yes | — | Exact trusted Lambda execution role |
| `tags` | No | `{}` | Role tags |

The commercial-partition sample `iam/automation-policy-commercial.json` is a template for reviewing an existing role. Replace both ARN placeholders before use. The Terraform target stack is preferred: it derives the active partition and scopes write resources to the configured account and AWS Region.

The tested update flow required:

- `mgn:DescribeSourceServers`
- `mgn:GetReplicationConfiguration`
- `mgn:UpdateReplicationConfiguration`
- EC2 describe and launch-template actions listed in the sample policy

`mgn:DescribeSourceServers` and the EC2 Describe APIs require wildcard resources, so those statements are constrained with `aws:RequestedRegion`. `mgn:GetReplicationConfiguration` and write permissions are scoped to source-server or launch-template resources in the configured account and Region. Launch-template changes also require the AWS Transform MGN managed tag to be present. Review CloudTrail and reduce policy scope further where your environment permits.

## Invocation schema

Direct invocation or EventBridge `detail` accepts:

| Field | Type | Default | Notes |
|---|---|---|---|
| `action` | string | `evaluate_replication_servers` | `evaluate_replication_servers` or `list_servers`; deprecated `list_disks` remains an alias |
| `auto_update` | JSON boolean | `false` | Strings such as `"false"` are rejected |
| `target_account_id` | string | deployment value | Optional; if supplied, must match deployment |
| `aws_region` | string | deployment value | Optional; if supplied, must match deployment |

## Response and validation

A dry-run server entry resembles:

```json
{
  "sourceServerID": "s-0123456789abcdef0",
  "hostname": "fileserver-01",
  "size_source": "sourceProperties.disks[].bytes",
  "inventory_complete": true,
  "source_capacity_gib": 12288.0,
  "replication_instance_check": {
    "current_instance": "t3.small",
    "target_instance": "m5.4xlarge",
    "meets_size_tier": true,
    "should_update": true,
    "decision_reason": "current type is in the configured baseline set",
    "dry_run": true
  }
}
```

For apply mode, verify `inventory_complete`, `updated`, and `new_instance`, then independently query AWS Transform MGN. A missing, zero, non-finite, non-numeric, or structurally invalid disk size makes the inventory incomplete; the function skips that server and does not select a tier:

```bash
aws mgn get-replication-configuration \
  --source-server-id <SOURCE_SERVER_ID> \
  --region <REGION> \
  --query replicationServerInstanceType \
  --output text
```

The function raises when any server fails. EventBridge retries failures delivering events to Lambda; Lambda separately retries handler/runtime failures after accepting an asynchronous invocation. Both exhausted paths use the same encrypted SQS dead-letter queue. Updates are not transactional; inspect the queue message type and CloudWatch Logs to identify servers changed before a later failure.

## Security and operational guidance

- One invocation evaluates every non-archived source server in the configured account and Region. Use a dedicated migration account/Region or add deployment-specific scoping before production use.
- Apply early in a wave. A type change replaces or restarts the replication server; replication resumes automatically but can re-drive data transfer. Allow enough time for replication to return to a healthy state before cutover.
- One invocation processes servers serially, and reserved concurrency prevents overlapping executions. Partition or implement fan-out for very large fleets.
- The function can promote a server from a lower configured tier to a higher tier when source capacity grows.
- It compares baseline and target size suffixes before updating, does not downgrade, and skips unknown/operator-selected types outside managed sets.
- Lambda responses and logs contain operational identifiers and source topology. Restrict invocation and CloudWatch Logs access and configure suitable retention.
- Terraform state can contain account IDs, ARNs, IP addresses, user data, and resource metadata. Use an encrypted, access-controlled remote backend with locking for shared or production deployments.
- Never publish state, local tfvars, Terraform plans, `.terraform/`, generated ZIPs, response files, or credentials. Build releases from a clean commit or explicit allowlist.
- Review current EC2 pricing, AWS Transform MGN behavior, quotas, and instance availability per AWS Region.
- Disable triggers after the migration wave.

## Cleanup

1. Set `enable_schedule=false` and apply.
2. Restore intended AWS Transform MGN replication instance types if required.
3. Destroy the standalone automation stack.
4. Destroy `stacks/target-account` only if this sample created a dedicated role.

Destroying Terraform does not revert AWS Transform MGN replication settings.
