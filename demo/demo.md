# Evidencia de funcionamiento (E2E)

Salidas y capturas del flujo completo, generadas con `./scripts/e2e-test.sh`.
Cubre los criterios de aceptación de
[`specs/event-platform.spec.md`](../specs/event-platform.spec.md).

## Contexto

- Región: `us-east-1`
- Endpoint: `https://xxxxx.execute-api.us-east-1.amazonaws.com/events`
- Fecha de la prueba: `____`

---

## Caso 1 — Evento normal se procesa (AC-1)

```bash
curl -X POST "$ENDPOINT" -H 'content-type: application/json' \
  -d '{"id":"abc-123","type":"pedido","payload":{"monto":50}}'
```

Verificación en DynamoDB:
```bash
aws dynamodb get-item --table-name event-platform-events \
  --key '{"id":{"S":"abc-123"}}'
```

Esperado: respuesta rápida de la API y un item en la tabla con `processedAt`.

_(captura: item en DynamoDB)_

---

## Caso 2 — Idempotencia (AC-2)

Mismo `id` otra vez:
```bash
curl -X POST "$ENDPOINT" -H 'content-type: application/json' \
  -d '{"id":"abc-123","type":"pedido","payload":{"monto":50}}'
```

Verificación en logs:
```bash
aws logs tail /aws/lambda/event-platform-processor --since 3m
```

Esperado: en el log aparece `evento abc-123 ya estaba procesado, lo ignoro
(idempotencia)` y en DynamoDB sigue habiendo un solo item.

_(captura: línea de log)_

---

## Caso 3 — Fallo, reintentos y DLQ (AC-3 / AC-4)

Evento venenoso:
```bash
curl -X POST "$ENDPOINT" -H 'content-type: application/json' \
  -d '{"id":"veneno-1","forceFail":true}'
```

Tras ~3 reintentos, el mensaje cae en la DLQ:
```bash
aws sqs get-queue-attributes --queue-url "$DLQ" \
  --attribute-names ApproximateNumberOfMessages
```

Esperado: `ApproximateNumberOfMessages: "1"` y en los logs los 3 intentos
fallando con `forceFail activo...`.

_(captura: mensajes en la DLQ + alarma en estado ALARM)_

---

## Caso 4 — Alerta (AC-5)

Cuando la DLQ deja de estar vacía, la alarma `event-platform-dlq-not-empty`
pasa a `ALARM` y SNS manda correo.

_(captura: correo de alerta / alarma en ALARM)_

---

## Teardown (AC-6)

```bash
./scripts/teardown.sh
```

Esperado: `Destroy complete!`.
