# Tabla donde el procesador guarda los eventos. Cumple dos roles:
#  1) almacenamiento del resultado del procesamiento;
#  2) registro de idempotencia: la clave 'id' + escritura condicional evita
#     guardar el mismo evento dos veces.
#
# PAY_PER_REQUEST (on-demand): cero capacidad que aprovisionar, escala solo y a
# volumen de demo el costo es prácticamente $0 (los 25 GB de almacenamiento son
# Always Free). En prod con tráfico predecible se puede pasar a provisionado.

resource "aws_dynamodb_table" "events" {
  name         = "${var.project_name}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}
