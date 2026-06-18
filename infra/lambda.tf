# Procesador: Lambda en Go (arm64), disparado por SQS, escala con la cola.

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-processor"
  retention_in_days = 14
}

resource "aws_lambda_function" "processor" {
  function_name = "${var.project_name}-processor"
  role          = aws_iam_role.lambda.arn

  # Runtime de Go: el binario se llama "bootstrap".
  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  timeout     = 10
  memory_size = 128

  publish = true # versión por deploy, para rollback

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.events.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# Alias "live": rollback = mover el alias a la versión anterior.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.processor.function_name
  function_version = aws_lambda_function.processor.version
}

# function_response_types habilita el fallo parcial por mensaje.
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_alias.live.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}
