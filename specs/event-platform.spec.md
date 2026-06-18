# Spec: Plataforma de ingesta y procesamiento de eventos

> Spec-driven: este documento define **qué** debe hacer el sistema y **cómo se
> verifica**. El código (`app/`) y la infraestructura (`infra/`) se derivan de
> aquí. Si algo del código no cumple una de estas reglas, el código está mal,
> no la spec.

## 1. Contexto

Recibimos un flujo irregular y con picos de eventos de negocio. Dos equipos
distintos son dueños de "recibir" y "procesar", así que ambos lados tienen que
poder evolucionar y escalar por separado. No se puede perder un evento aunque
el procesador esté caído o lento.

## 2. Actores

- **Productor**: cualquier cliente que manda eventos por HTTP (otro servicio,
  un dispositivo, un webhook).
- **Plataforma de ingesta**: recibe y encola (equipo A).
- **Procesador**: consume, transforma y guarda (equipo B).
- **Operador**: recibe alertas y revisa la DLQ.

## 3. Contrato de entrada (API)

`POST /events` con cuerpo JSON:

```json
{
  "id": "string, requerido, único por evento de negocio",
  "type": "string, opcional",
  "payload": { "objeto libre, opcional" },
  "forceFail": "bool, opcional, SOLO para demo de fallos"
}
```

- **REQ-IN-1**: el endpoint responde rápido (no espera al procesamiento). El
  evento queda en una cola durable antes de devolver respuesta.
- **REQ-IN-2**: la recepción no comparte proceso ni despliegue con el
  procesamiento (desacople real).
- **REQ-IN-3**: el `id` es la clave de idempotencia y lo provee el productor.

## 4. Reglas de procesamiento

- **REQ-PROC-1 (idempotencia)**: procesar el mismo `id` dos o más veces deja
  exactamente un registro. La segunda vez se ignora sin error.
- **REQ-PROC-2 (reintentos)**: un fallo transitorio se reintenta hasta
  `max_receive_count` veces (default 3).
- **REQ-PROC-3 (venenosos)**: un mensaje que falla siempre (JSON inválido, sin
  `id`, o `forceFail`) termina en una Dead Letter Queue tras agotar reintentos,
  sin bloquear al resto.
- **REQ-PROC-4 (escalado independiente)**: el procesamiento escala según la
  profundidad de la cola, sin tocar la recepción.
- **REQ-PROC-5 (fallo parcial)**: si en un lote un mensaje falla, solo ese
  vuelve a la cola; los que salieron bien no se reprocesan.

## 5. Seguridad

- **REQ-SEC-1**: ningún componente usa llaves/credenciales embebidas. Todo es
  identidad de workload (roles IAM asumidos por el servicio).
- **REQ-SEC-2**: mínimo privilegio. Cada rol solo puede hacer lo justo sobre el
  recurso justo (sin `*` en recursos).
- **REQ-SEC-3**: no hay secretos en el repo. El email de alertas se pasa por
  variable, no se commitea (`terraform.tfvars` va en `.gitignore`).

## 6. Operabilidad y costo

- **REQ-OPS-1**: toda la infra es código (Terraform) y se levanta de cero con
  un comando, y se destruye con otro (teardown).
- **REQ-OPS-2**: hay logs estructurados y alarmas: una si la DLQ deja de estar
  vacía, otra si el procesador acumula errores.
- **REQ-OPS-3**: existe una alerta de presupuesto mensual.
- **REQ-OPS-4**: rollback rápido del procesador vía versiones + alias de Lambda.
- **REQ-COST-1**: todo cae en la capa gratuita de AWS a volumen de demo (ver
  `VIABILIDAD-capa-gratuita.md`).

## 7. Criterios de aceptación (E2E verificables)

| # | Escenario | Resultado esperado |
|---|-----------|--------------------|
| AC-1 | `POST /events` con evento nuevo | 200 rápido; aparece 1 item en DynamoDB |
| AC-2 | `POST /events` con el mismo `id` otra vez | sigue habiendo 1 item; log "idempotencia" |
| AC-3 | `POST /events` con `forceFail:true` | tras 3 reintentos el mensaje aparece en la DLQ |
| AC-4 | Cuerpo sin `id` o no-JSON | termina en la DLQ (veneno), no bloquea otros |
| AC-5 | DLQ con ≥1 mensaje | la alarma dispara y llega correo al operador |
| AC-6 | `terraform destroy` | no quedan recursos facturables |

Estos criterios se ejercitan con `scripts/e2e-test.sh` y se evidencian en
`demo/demo.md`.
