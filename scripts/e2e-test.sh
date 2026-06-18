#!/usr/bin/env bash
set -euo pipefail

# Prueba E2E del flujo completo (cubre los criterios de aceptación de la spec):
#   1) evento normal -> se procesa y se guarda (AC-1)
#   2) mismo evento otra vez -> idempotencia (AC-2)
#   3) evento venenoso (forceFail) -> reintentos -> DLQ (AC-3)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/infra"

ENDPOINT="$(terraform output -raw events_endpoint)"
TABLE="$(terraform output -raw table_name)"
DLQ="$(terraform output -raw dlq_url)"
REGION="$(terraform output -raw region)"

ID="evt-$(date +%s)"

echo "=================================================="
echo "1) Evento NUEVO (id=$ID)"
echo "=================================================="
curl -s -X POST "$ENDPOINT" -H 'content-type: application/json' \
  -d "{\"id\":\"$ID\",\"type\":\"demo\",\"payload\":{\"hola\":\"mundo\"}}"
echo
echo "Esperando a que el procesador consuma..."
sleep 8
echo "-- Item en DynamoDB (debe existir) --"
aws dynamodb get-item --region "$REGION" --table-name "$TABLE" \
  --key "{\"id\":{\"S\":\"$ID\"}}"

echo
echo "=================================================="
echo "2) MISMO evento otra vez (idempotencia)"
echo "=================================================="
curl -s -X POST "$ENDPOINT" -H 'content-type: application/json' \
  -d "{\"id\":\"$ID\",\"type\":\"demo\",\"payload\":{\"hola\":\"mundo\"}}"
echo
sleep 6
echo "Revisa los logs: debe decir 'ya estaba procesado, lo ignoro (idempotencia)'"
echo "aws logs tail $(terraform output -raw log_group) --region $REGION --since 2m"

echo
echo "=================================================="
echo "3) Evento VENENOSO (forceFail) -> reintentos -> DLQ"
echo "=================================================="
curl -s -X POST "$ENDPOINT" -H 'content-type: application/json' \
  -d "{\"id\":\"poison-$ID\",\"type\":\"demo\",\"forceFail\":true}"
echo
echo "Espera ~1-2 min (3 reintentos) y revisa cuántos mensajes hay en la DLQ:"
echo "aws sqs get-queue-attributes --region $REGION --queue-url $DLQ \\"
echo "  --attribute-names ApproximateNumberOfMessages"
