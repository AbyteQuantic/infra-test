# Cola que desacopla recepción y procesamiento.

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-dlq"
  message_retention_seconds = 1209600 # 14 días para inspeccionar venenosos
}

resource "aws_sqs_queue" "main" {
  name = "${var.project_name}-events"

  visibility_timeout_seconds = 60     # >= 6x el timeout del Lambda
  message_retention_seconds  = 345600 # 4 días

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# La DLQ solo acepta redrive desde la cola principal.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}
