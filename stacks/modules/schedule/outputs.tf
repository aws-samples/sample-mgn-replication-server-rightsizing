output "rule_name" {
  description = "EventBridge schedule rule name."
  value       = aws_cloudwatch_event_rule.schedule.name
}

output "dead_letter_queue_arn" {
  description = "SQS dead-letter queue ARN for EventBridge and Lambda asynchronous failures."
  value       = aws_sqs_queue.dlq.arn
}

output "dead_letter_queue_url" {
  description = "SQS dead-letter queue URL."
  value       = aws_sqs_queue.dlq.url
}
