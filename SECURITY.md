# Security

## Reporting security issues

If you discover a potential security issue in this project, notify AWS/Amazon Security through the [vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/) or by email at [aws-security@amazon.com](mailto:aws-security@amazon.com). Do **not** create a public GitHub issue.

## Disclaimer

This is sample code intended to demonstrate a pattern. It is not production software. Review, test, and harden it against your own security requirements before deploying to any production environment.

## Production hardening recommendations

The sample includes least-privilege IAM, account guardrails, dry-run-by-default behavior, and an encrypted, TLS-only dead-letter queue. Before production use, also consider the following:

- **Encryption with customer managed keys.**
  - Set `log_kms_key_arn` to a customer managed AWS KMS key for the Lambda log group. The key policy must allow the `logs.<region>.amazonaws.com` service principal.
  - Set `kms_key_arn` on the `aws_lambda_function` resource in `stacks/modules/autoscaler` to encrypt environment variables with a customer managed key, and grant the execution role `kms:Decrypt` on that key.
- **Network isolation.** If your policy requires it, deploy the Lambda function into private subnets with interface VPC endpoints for AWS STS, AWS Transform MGN, and Amazon EC2, and restrict security group egress to HTTPS.
- **Observability.** Enable AWS X-Ray active tracing, alarm on messages in the dead-letter queue, and audit `UpdateReplicationConfiguration` calls with AWS CloudTrail.
- **Deployment integrity.** Enforce AWS Lambda code signing with an AWS Signer signing profile.
- **Invocation access.** Grant `lambda:InvokeFunction` only to approved operators and automation; any authorized invoker can request apply mode.
- **Terraform state.** Use an encrypted, access-controlled remote backend with state locking.

See the [Security section of the README](README.md#security) for the controls included by default.
