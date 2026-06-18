# Puerta de entrada. HTTP API con integración directa a SQS: escribe el cuerpo
# en la cola sin compute nuestro de por medio (sin cold starts en la puerta).

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "sqs" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_subtype    = "SQS-SendMessage"
  credentials_arn        = aws_iam_role.apigw_sqs.arn
  payload_format_version = "1.0"

  request_parameters = {
    "QueueUrl"    = aws_sqs_queue.main.url
    "MessageBody" = "$request.body"
  }
}

resource "aws_apigatewayv2_route" "post_events" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /events"
  target    = "integrations/${aws_apigatewayv2_integration.sqs.id}"
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  # Throttling para acotar abuso y costo.
  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 50
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}
