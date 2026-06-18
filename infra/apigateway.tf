# La puerta de entrada. Usamos HTTP API (v2) con integración DIRECTA a SQS:
# API Gateway escribe el cuerpo del request en la cola sin pasar por ningún
# compute nuestro. Es lo más resiliente para "aceptar rápido y no perder":
# el evento aterriza en una cola durable de inmediato, sin cold starts ni
# límites de concurrencia de Lambda en la puerta.

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

  # Throttling para protegernos de abuso y mantenernos en free tier.
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
