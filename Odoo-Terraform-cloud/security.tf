# =================================================================
# 1. DATOS DE LA CUENTA Y VARIABLES LOCALES
# =================================================================

# Esto obtiene tu ID de cuenta de AWS automáticamente
data "aws_caller_identity" "current" {}

# =================================================================
# 2. ALMACENAMIENTO (S3 BUCKET PARA LOGS)
# =================================================================

resource "aws_s3_bucket" "security_logs" {
  bucket        = "odoo-security-logs-${data.aws_caller_identity.current.account_id}" 
  force_destroy = true # Útil para pruebas: permite borrar el bucket aunque tenga logs
}

# Política para que CloudTrail y Config puedan escribir en el Bucket
resource "aws_s3_bucket_policy" "security_logs_policy" {
  bucket = aws_s3_bucket.security_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Declaración 1: Permite a los servicios verificar el estado del bucket
      {
        Sid    = "AllowServiceChecks"
        Effect = "Allow"
        Principal = { 
          Service = ["cloudtrail.amazonaws.com", "config.amazonaws.com"] 
        }
        Action   = ["s3:GetBucketAcl", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.security_logs.arn
      },
      # Declaración 2: Permite a los servicios SUBIR los logs (aquí va la condición)
      {
        Sid    = "AllowServiceWrites"
        Effect = "Allow"
        Principal = { 
          Service = ["cloudtrail.amazonaws.com", "config.amazonaws.com"] 
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.security_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { 
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } 
        }
      }
    ]
  })
}

# =================================================================
# 3. AWS CLOUDTRAIL (AUDITORÍA DE ACCIONES)
# =================================================================

resource "aws_cloudtrail" "main" {
  name                          = "odoo-management-trail"
  s3_bucket_name                = aws_s3_bucket.security_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.security_logs_policy]
}

# =================================================================
# 4. AWS CONFIG (GESTIÓN DE CONFIGURACIÓN)
# =================================================================

# Primero necesitamos un Rol de IAM para que Config pueda "mirar" tus recursos
resource "aws_iam_role" "config_role" {
  name = "aws-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

# Le damos permiso de lectura al rol de Config
resource "aws_iam_role_policy_attachment" "config_policy" {
  role       = aws_iam_role.config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# El Grabador: el que saca las "fotos" de la configuración
resource "aws_config_configuration_recorder" "main" {
  name     = "odoo-config-recorder"
  role_arn = aws_iam_role.config_role.arn

  recording_group {
    all_supported                = true
    include_global_resource_types = true
  }
}

# El Canal de Entrega: a dónde envía las fotos (nuestro S3)
resource "aws_config_delivery_channel" "main" {
  name           = "odoo-delivery-channel"
  s3_bucket_name = aws_s3_bucket.security_logs.id
  depends_on     = [aws_config_configuration_recorder.main]
}

# Encendemos el grabador
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}
# =================================================================
# 5. NOTIFICACIONES (SNS) - CORREGIDO
# =================================================================

# Creamos un "Tema" (un canal de alertas)
resource "aws_sns_topic" "security_alerts" {
  name = "odoo-security-alerts-topic"
}

# Nos suscribimos al canal (aquí pones tu email)
resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = "santiago.suarez@zconsulting.com.ar"
}