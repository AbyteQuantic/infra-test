variable "project_name" {
  description = "Prefijo para nombrar todos los recursos"
  type        = string
  default     = "event-platform"
}

variable "region" {
  description = "Región AWS. us-east-1 tiene la mejor cobertura de free tier."
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email para alertas (DLQ, errores) y para la alerta de presupuesto"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Tope mensual en USD para disparar la alerta de presupuesto"
  type        = number
  default     = 1
}

variable "max_receive_count" {
  description = "Reintentos de un mensaje antes de mandarlo a la DLQ"
  type        = number
  default     = 3
}

variable "lambda_zip_path" {
  description = "Ruta al zip del Lambda (lo genera scripts/build.sh)"
  type        = string
  default     = "../app/processor/build/processor.zip"
}
