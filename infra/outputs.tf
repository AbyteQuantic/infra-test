output "api_endpoint" {
  description = "URL base de la API"
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "events_endpoint" {
  description = "Endpoint de ingesta (POST acá tus eventos)"
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/events"
}

output "main_queue_url" {
  value = aws_sqs_queue.main.url
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "table_name" {
  value = aws_dynamodb_table.events.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.lambda.name
}

output "region" {
  value = var.region
}
