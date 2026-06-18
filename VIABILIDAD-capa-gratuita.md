# Viabilidad en capa gratuita (AWS)

Resumen de por qué esto corre a **$0** a volumen de prueba, y qué lo vigila.

## Servicios del camino crítico y su free tier

| Servicio | Free tier | ¿Always Free? | Uso en la demo |
|----------|-----------|---------------|----------------|
| **Lambda** | 1M invocaciones + 400.000 GB-s / mes | Sí | decenas de invocaciones |
| **SQS** | 1M requests / mes (suma de colas) | Sí | decenas de mensajes |
| **DynamoDB** | 25 GB almacenamiento; 25 RCU/25 WCU si fuera provisionado | Sí | unos pocos KB |
| **CloudWatch** | 10 alarmas, 5 GB logs, 1M métricas API / mes | Sí | 2 alarmas + logs mínimos |
| **SNS** | 1.000 emails / mes | Sí | un par de correos |
| **API Gateway (HTTP API)** | 1M requests / mes | Solo 12 meses | decenas de requests |

El único que no es Always Free es API Gateway HTTP API (gratis 12 meses, luego
~$1.00 por millón de requests). A volumen de demo son centavos. El resto es
gratis para siempre.

## Decisiones tomadas para no salirnos de free tier

- **Serverless, escala a cero:** sin servidores encendidos 24/7. Si no entran
  eventos, no se gasta.
- **Sin EKS:** el control plane de Kubernetes administrado en AWS cuesta
  ~$73/mes. Lo evitamos por completo.
- **Sin NAT Gateway / VPC:** no hace falta red privada para el MVP; el NAT
  gateway es uno de los costos "sorpresa" más comunes y no es free.
- **DynamoDB on-demand:** a este volumen el costo de requests es ~$0 y los 25 GB
  de almacenamiento son gratis.
- **Logs con retención de 14 días:** evitamos acumular logs (y costo) para
  siempre.
- **arm64 (Graviton):** más barato por GB-s que x86.

## Red de seguridad

- **AWS Budgets** a $1/mes con alerta al 80% (gasto real) y 100% (proyectado) →
  email. Si algo se dispara, te enteras el mismo día.
- **`scripts/teardown.sh`** (`terraform destroy`) borra todo lo facturable al
  terminar.
- **Región:** `us-east-1` por defecto (mejor cobertura de free tier).

## Fuentes

- AWS Free Tier: https://aws.amazon.com/free/
- Precios SQS: https://aws.amazon.com/sqs/pricing/
- Precios Lambda: https://aws.amazon.com/lambda/pricing/
- Precios DynamoDB: https://aws.amazon.com/dynamodb/pricing/on-demand/
- Precios API Gateway: https://aws.amazon.com/api-gateway/pricing/
