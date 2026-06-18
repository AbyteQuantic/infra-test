# Decisiones de arquitectura

## 1. Caso entendido

Necesitamos una plataforma que reciba un flujo irregular y con picos de eventos
de negocio, donde "recibir" y "procesar" los manejan equipos distintos. La
recepción tiene que aceptar rápido y no perder nada aunque el procesador esté
caído o lento; el procesamiento es asíncrono, con reintentos, un destino para
los eventos que fallan siempre (venenosos) e idempotente para no duplicar
efectos. Cada lado debe escalar y desplegarse por separado, y todo tiene que ser
seguro (identidad sin llaves, mínimo privilegio, sin secretos en el repo),
reproducible (infra como código + teardown), observable y de bajo costo (capa
gratuita).

## 2. Arquitectura elegida + por qué

**Patrón:** ingesta serverless desacoplada por cola.

```
Productor → API Gateway (HTTP API) → SQS → Lambda (Go) → DynamoDB
                                       └── DLQ → CloudWatch → SNS → email
```

(Diagrama completo en [`diagrama.md`](diagrama.md).)

La columna vertebral es **una cola en el medio**. La recepción solo deja el
evento en la cola y responde; el procesamiento consume a su ritmo. Eso resuelve
de un solo golpe el desacople (los dos lados no se conocen), la resiliencia ante
picos (la cola absorbe el golpe) y el escalado independiente (cada lado escala
por su cuenta).

Elegí **serverless puro** (sin Kubernetes) porque para un MVP de 1 día que debe
costar $0 y "verse funcionar", pagar y operar un cluster es sobre-ingeniería:
más piezas, más superficie de error, y en AWS el control plane de EKS cuesta
~$73/mes (no es free tier). Con managed services el "ops" se reduce a IAM y
alarmas, y el escalado a cero sale gratis.

La decisión más fina fue la **puerta de entrada**: API Gateway escribe **directo
en SQS** (integración nativa), sin un Lambda nuestro en el camino. Así la
recepción no tiene cold starts ni límites de concurrencia propios: el evento
aterriza en una cola durable de inmediato, que es exactamente lo que pide
"aceptar rápido y no perder ante picos".

## 3. Componentes y justificación

| Capa | Elección | Por qué |
|------|----------|---------|
| **Cómputo** | AWS Lambda (Go, arm64) | Escala a cero, escala solo con la cola, pago por uso. Go en arm64/Graviton = binario chico, arranque en frío rápido, más barato. |
| **Mensajería/eventos** | Amazon SQS + DLQ | Cola durable y simple. Trae reintentos y DLQ *nativos* (`maxReceiveCount`), justo lo que el caso pide. 1M requests/mes Always Free. |
| **Almacenamiento** | DynamoDB (on-demand) | Sirve de almacén y de registro de idempotencia (escritura condicional atómica). 25 GB Always Free, escala solo. |
| **Entrada** | API Gateway HTTP API → SQS directo | Interfaz HTTP gestionada; sin compute propio en la puerta = más resiliente y barato. |
| **IaC** | Terraform | Estándar de industria, multi-nube, `plan`/`apply`/`destroy` claros. Un archivo por componente. |
| **Identidad/Seguridad** | Roles IAM | Identidad de workload sin llaves; mínimo privilegio por recurso. |
| **Red** | Endpoints públicos gestionados | Para el MVP no hace falta VPC: SQS/DynamoDB/Lambda se hablan por el backbone de AWS vía IAM. Menos piezas, menos costo (NAT gateway no es free). |
| **Observabilidad** | CloudWatch Logs + Alarms, SNS | Logs por componente; alarmas de DLQ y de errores que avisan por correo. |
| **Costo** | AWS Budgets | Alerta de presupuesto al 80%/100%. |

## 4. Nube elegida (AWS) y cómo se mantiene en capa gratuita

**AWS**, porque el patrón "ingesta resiliente de eventos" calza perfecto con sus
managed services y todos los del camino crítico están en **Always Free** (no
solo 12 meses):

- **Lambda:** 1M de invocaciones y 400.000 GB-s gratis al mes, para siempre.
- **SQS:** 1M de requests/mes gratis, para siempre (cuenta principal + DLQ).
- **DynamoDB:** 25 GB de almacenamiento gratis, para siempre.
- **CloudWatch:** 10 alarmas y 5 GB de logs gratis al mes.
- **SNS:** 1.000 notificaciones por email gratis al mes.
- **API Gateway (HTTP API):** 1M de requests/mes gratis los primeros 12 meses;
  después ~$1.00/millón. A volumen de demo son centavos, y el Budget lo vigila.

A escala de prueba (decenas/cientos de eventos) el gasto real es **$0**. La
alarma de presupuesto a $1 es la red de seguridad, y el `teardown.sh` deja todo
en cero al terminar. Detalle y fuentes en
[`VIABILIDAD-capa-gratuita.md`](VIABILIDAD-capa-gratuita.md).

## 5. Cómo cumple desacople, resiliencia y escalado independiente

**Desacople real:** entre recepción y procesamiento solo hay una cola. El equipo
A (API Gateway) no sabe quién consume; el equipo B (Lambda) no sabe quién
produce. Cada uno despliega su parte sin coordinar con el otro.

**Resiliencia:**
- *Picos / caídas:* si el procesador está caído o lento, los eventos se acumulan
  en SQS (retención 4 días) y se procesan cuando vuelva. No se pierde nada.
- *Reintentos:* SQS reentrega un mensaje fallido hasta `max_receive_count` (3)
  veces antes de descartarlo del flujo normal.
- *Venenosos:* tras esos 3 intentos, el mensaje va a la **DLQ** (retención 14
  días) para inspección/reproceso, sin bloquear al resto de la cola.
- *Idempotencia:* el procesador escribe en DynamoDB con
  `attribute_not_exists(id)`. Como SQS es "al menos una vez", un mismo evento
  puede llegar dos veces; la escritura condicional garantiza un solo registro.
  El `id` lo provee el productor y es estable entre reintentos.
- *Fallo parcial:* el Lambda usa `ReportBatchItemFailures`: si en un lote de 10
  uno falla, solo ese vuelve a la cola; los otros 9 no se reprocesan.

**Escalado independiente:** la recepción (API Gateway) escala sola y aparte. El
procesamiento escala según la profundidad de la cola (Lambda levanta más
ejecuciones concurrentes si hay más mensajes). Subir el throughput de un lado no
toca al otro.

## 6. Seguridad

- **Identidad de workloads sin llaves:** API Gateway asume un rol IAM para
  escribir en SQS; el Lambda usa su rol de ejecución. Cero access keys, cero
  secretos en variables de entorno sensibles.
- **Mínimo privilegio:** cada política lista acciones concretas sobre ARNs
  concretos. El rol de API Gateway solo puede `sqs:SendMessage` en *esa* cola.
  El del Lambda solo lee de *esa* cola, hace `PutItem` en *esa* tabla y escribe
  en *su* log group. Sin `Resource: "*"`.
- **Secretos fuera del repo:** no hay credenciales en el código. Lo único
  sensible (el email) va por variable en `terraform.tfvars`, que está en
  `.gitignore`. El repo trae un `.example`.
- **Superficie mínima:** un solo endpoint (`POST /events`) con throttling.

## 7. Operabilidad

- **Observabilidad:** logs en CloudWatch por componente (Lambda y access logs de
  API Gateway). Dos alarmas: (1) DLQ con ≥1 mensaje, (2) errores del procesador.
  Ambas notifican por SNS → email.
- **Despliegue/CI:** GitHub Actions corre en cada push: `go vet`, `go test
  -cover`, `terraform fmt -check` y `terraform validate`. El deploy real lo
  dispara una persona con `deploy.sh` (en prod sería OIDC + un job de `apply`).
- **Rollback:** el Lambda se publica con versiones y un alias `live`; volver
  atrás es mover el alias a la versión anterior (segundos, sin redeploy). La
  infra se revierte con `git revert` + `terraform apply`.

## 8. Alternativas consideradas y descartadas

| Alternativa | Por qué la descarté |
|-------------|---------------------|
| **EKS / Kubernetes** | Control plane ~$73/mes (no free tier) y demasiada operación para un MVP de 1 día. Sobre-ingeniería para este alcance. |
| **API Gateway → Lambda → SQS** (un Lambda en la puerta) | Agrega compute y cold starts en el camino crítico, y un límite de concurrencia propio en la recepción. La integración directa a SQS es más resiliente y barata. *Trade-off:* perdemos validación rica en la puerta (lo resolvemos validando en el procesador; los inválidos caen a la DLQ). En prod se puede sumar un request validator de REST API o WAF. |
| **EventBridge** | Excelente para enrutar/fan-out por reglas, pero acá queremos una cola con backlog, reintentos y DLQ simples. SQS es más directo para "buffer + worker". EventBridge entraría si aparecen múltiples consumidores por tipo de evento. |
| **Kinesis / MSK (Kafka)** | Para alto throughput sostenido y orden estricto/replay. Es más caro y operativamente pesado; el caso (picos irregulares, un consumidor) no lo justifica. |
| **SQS FIFO** | Da dedupe y orden, pero con menor throughput y más restricciones. Preferí SQS estándar + idempotencia en la app: más simple y suficiente. |
| **RDS/Postgres para idempotencia** | Implica servidor siempre encendido (no escala a cero, no tan "free"). DynamoDB on-demand encaja mejor con serverless. |
| **GCP (Cloud Run + Pub/Sub)** | Solución igual de válida y también $0. Elegí AWS por la integración nativa API Gateway→SQS y porque IAM es un caso de libro de "identidad sin llaves". Con GCP el patrón sería equivalente. |

## 9. Producción + liderazgo

**Qué haría distinto en prod:**
- **Validación y contrato en la puerta:** JSON Schema (REST API request
  validator) o validación en un Lambda fino, + WAF y autenticación
  (API keys/Cognito/mTLS según el productor).
- **Idempotencia con TTL:** agregar `expiresAt` a DynamoDB (TTL) para no guardar
  llaves de idempotencia para siempre.
- **Entrega de resultados:** además de guardar, publicar a downstream
  (EventBridge/SNS) si otros equipos necesitan reaccionar.
- **Despliegue:** pipeline con OIDC (sin llaves en CI), `plan` en PR + `apply`
  con aprobación, despliegue canary del Lambda moviendo el alias por porcentaje.
- **Observabilidad:** dashboard, métricas de edad del mensaje más viejo en cola,
  trazas con X-Ray, y SLOs (latencia de procesamiento, tasa a DLQ).
- **Estado de Terraform:** backend remoto (S3 + DynamoDB lock) en vez de local.
- **Red:** VPC + VPC endpoints si hay requisitos de aislamiento/compliance.

**Cómo lo lideraría con el equipo:**
- **Contratos primero:** el `id` y el esquema del evento son el contrato entre
  el equipo A y el B. Lo fijamos en las `specs/` y versionamos; nadie rompe el
  contrato sin avisar. Eso es lo que hace que ambos equipos avancen en paralelo.
- **Ownership claro:** equipo A es dueño de API Gateway + cola de entrada;
  equipo B del Lambda + tabla. La DLQ y las alarmas son responsabilidad
  compartida con un runbook ("llegó alerta de DLQ → revisar → reprocesar").
- **Roadmap por riesgo:** primero seguridad de la puerta (auth + validación),
  luego observabilidad/SLOs, luego optimizaciones de costo/escala. Cada paso
  entra detrás de su alarma; no se sube nada sin forma de verlo y revertirlo.
- **Costo como hábito:** tags por proyecto + Budgets desde el día 1; revisión
  mensual de gasto. La regla es "escala a cero por defecto".
- **Riesgos que vigilaría:** envenenamiento masivo de la cola (mitigado con DLQ
  + alarma), límites de concurrencia de Lambda bajo un pico real (reservar/elevar
  cuota), y crecimiento de la tabla de idempotencia (TTL).
