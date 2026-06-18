# Almacén de eventos y registro de idempotencia (clave 'id').
# On-demand: escala solo y a volumen de demo cuesta ~$0 (25 GB Always Free).

resource "aws_dynamodb_table" "events" {
  name         = "${var.project_name}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}
