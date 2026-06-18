# La cola es el corazón del desacople: la recepción solo encola y responde,
# el procesamiento consume a su propio ritmo. Si el procesador está caído o
# lento, los eventos se quedan acá esperando (no se pierden).

resource "aws_sqs_queue" "dlq" {
  name = "${var.project_name}-dlq"
  # 14 días: damos tiempo de sobra para inspeccionar/reprocesar venenosos.
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "main" {
  name = "${var.project_name}-events"

  # Visibility timeout >= 6x el timeout del Lambda (10s) es la recomendación
  # de AWS para que un mensaje no se reentregue mientras todavía se procesa.
  visibility_timeout_seconds = 60

  # 4 días de retención de eventos sin procesar (margen ante una caída larga).
  message_retention_seconds = 345600

  # redrive_policy = a dónde van los mensajes que fallan demasiadas veces.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# La DLQ solo acepta mensajes redrive desde la cola principal (mínimo privilegio
# a nivel de cola).
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}
