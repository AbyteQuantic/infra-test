# El procesador: un Lambda en Go (arm64/Graviton, más barato y rápido en frío).
# Lo dispara SQS y escala solo según la cantidad de mensajes en la cola, de
# forma totalmente independiente de la recepción.

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-processor"
  retention_in_days = 14
}

resource "aws_lambda_function" "processor" {
  function_name = "${var.project_name}-processor"
  role          = aws_iam_role.lambda.arn

  # Runtime personalizado para Go: el binario se llama "bootstrap".
  runtime       = "provided.al2023"
  handler       = "bootstrap"
  architectures = ["arm64"]

  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  timeout     = 10
  memory_size = 128

  # publish = true crea una versión inmutable en cada deploy -> permite rollback.
  publish = true

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.events.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# Alias "live": apunta a la versión activa. Para hacer rollback basta mover el
# alias a la versión anterior (sin redeploy).
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.processor.function_name
  function_version = aws_lambda_function.processor.version
}

# Conecta la cola con el Lambda. function_response_types habilita el manejo de
# fallos parciales por mensaje (no reprocesa el lote entero si uno falla).
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_alias.live.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}
