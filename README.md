# Plataforma de ingesta y procesamiento de eventos (AWS, serverless)

Recibe un flujo irregular de eventos por HTTP, los encola y los procesa de forma
asíncrona, con reintentos, manejo de venenosos (DLQ) e idempotencia. Todo como
código (Terraform) y dentro de la capa gratuita de AWS.

- **Recepción:** API Gateway (HTTP API) → escribe directo en SQS.
- **Cola:** SQS (desacople) + DLQ (venenosos).
- **Procesamiento:** Lambda en Go → DynamoDB (idempotente).
- **Operación:** CloudWatch (logs + alarmas), SNS (email), AWS Budgets.
- **Identidad:** roles IAM (sin llaves), mínimo privilegio.

Diseño y justificación completos en [`DECISIONES.md`](DECISIONES.md).
Diagrama en [`diagrama.md`](diagrama.md). Specs en [`specs/`](specs/).

```
app/processor/   Lambda de procesamiento (Go) + tests
infra/           Terraform (un archivo por componente)
scripts/         build / deploy / e2e-test / teardown
specs/           specs del sistema (spec-driven)
demo/            evidencia del flujo E2E
```

## Requisitos

- Cuenta de AWS con la CLI autenticada (`aws configure` o SSO).
- Terraform >= 1.5
- Go >= 1.22
- `zip`, `curl` (vienen en macOS/Linux)

## Desplegar de cero

```bash
# 1. Configura tus variables (email para alertas, región, presupuesto)
cp infra/terraform.tfvars.example infra/terraform.tfvars
$EDITOR infra/terraform.tfvars        # pon tu correo real

# 2. Compila el Lambda y aplica la infra
./scripts/deploy.sh
```

`deploy.sh` compila el binario de Go, corre los tests, y hace `terraform apply`.
Al final imprime el **endpoint de ingesta**.

Tras el primer apply, AWS manda un correo "AWS Notification - Subscription
Confirmation" al email configurado. Hay que abrirlo y confirmar la suscripción
para recibir las alertas de SNS.

## Probar el flujo E2E

```bash
./scripts/e2e-test.sh
```

Ejercita los 3 casos (cubren los criterios de aceptación de la spec):

1. **Evento normal** → aparece en DynamoDB.
2. **Mismo evento otra vez** → no se duplica (idempotencia; se ve en los logs).
3. **Evento venenoso** (`forceFail:true`) → se reintenta 3 veces y cae en la DLQ
   → dispara la alarma → te llega correo.

Manual, si prefieres:

```bash
ENDPOINT=$(cd infra && terraform output -raw events_endpoint)

# evento normal
curl -X POST "$ENDPOINT" -H 'content-type: application/json' \
  -d '{"id":"abc-123","type":"pedido","payload":{"monto":50}}'

# caso de fallo -> DLQ
curl -X POST "$ENDPOINT" -H 'content-type: application/json' \
  -d '{"id":"veneno-1","forceFail":true}'
```

Ver logs del procesador:

```bash
aws logs tail "$(cd infra && terraform output -raw log_group)" --since 5m --follow
```

## Rollback

El Lambda se publica con versiones y un alias `live`. Para volver a la versión
anterior sin redeploy:

```bash
aws lambda update-alias \
  --function-name event-platform-processor \
  --name live \
  --function-version <VERSION_ANTERIOR>
```

Para revertir infra: `git revert` del commit y `terraform apply`.

## Teardown (importante)

```bash
./scripts/teardown.sh        # terraform destroy
```

Borra todo lo facturable. Hazlo al terminar la prueba.

## Troubleshooting

- **`terraform apply` falla por el zip del Lambda:** corre `./scripts/build.sh`
  primero (o usa `deploy.sh`, que ya lo hace).
- **No llegan alertas:** revisa que confirmaste la suscripción de SNS.
- **El access log de API Gateway da problemas al aplicar:** comenta el bloque
  `access_log_settings` en `infra/apigateway.tf` (no es crítico para el MVP).
