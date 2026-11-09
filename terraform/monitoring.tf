### MONITOREO: tópico SNS, alarmas de CloudWatch y dashboard
# Métricas propias (namespace ToDoListApi): la app las manda con put_metric_data en cada petición.
# Métrica de AWS: CPUUtilization de la EC2 (la publica EC2 sola, cada 5 min).

locals {
  metrics_namespace = "ToDoListApi" # igual que METRICS_NAMESPACE en app.py
}

### SNS: todas las alarmas avisan a este tópico, que manda correo
resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms"
}

# AWS manda un correo de confirmación; hasta que se acepta, no llegan las alertas.
# Con cada sandbox nuevo el tópico se crea de nuevo, así que hay que volver a confirmar.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

### Alarma 1 (métrica de AWS): CPU de la EC2
# t3.micro es burstable (baseline ~10%): CPU alta sostenida gasta los créditos y después la
# instancia se vuelve lenta. Dos periodos seguidos de 5 min para no alertar por un pico.
resource "aws_cloudwatch_metric_alarm" "ec2-cpu" {
  alarm_name          = "${var.project_name}-ec2-cpu-alta"
  alarm_description   = "CPU promedio de la EC2 arriba de 80% durante 10 minutos"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.server.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

### Alarma 2 (métrica propia): latencia
# p90 en lugar de promedio: el promedio esconde las peticiones lentas. Normalmente una petición
# tarda decenas de ms; más de 1 s es una API lenta (por ejemplo, RDS saturada o sin responder,
# donde cada conexión espera el connect_timeout de 5 s). 3 de 5 minutos: no alerta por un pico.
resource "aws_cloudwatch_metric_alarm" "latency" {
  alarm_name          = "${var.project_name}-latencia-alta"
  alarm_description   = "p90 de la latencia de la API arriba de 1 s en 3 de los últimos 5 minutos"
  namespace           = local.metrics_namespace
  metric_name         = "Latency"
  extended_statistic  = "p90"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching" # sin tráfico no hay datos, y eso no es un problema
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

### Alarma 3 (métrica propia): errores 5xx
# Un 5xx es una falla nuestra (BD caída, excepción no manejada), no del cliente. 3 en 5 min ya
# no es un error aislado; además coincide con el workflow Monitor, que pega a /health 3 veces
# (1 + 2 reintentos) cuando la BD falla.
resource "aws_cloudwatch_metric_alarm" "server-errors" {
  alarm_name          = "${var.project_name}-errores-5xx"
  alarm_description   = "3 o más respuestas 5xx en 5 minutos"
  namespace           = local.metrics_namespace
  metric_name         = "ServerErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

### DASHBOARD
# Las líneas horizontales marcan el umbral de cada alarma.
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "alarm"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          title = "Alarmas"
          alarms = [
            aws_cloudwatch_metric_alarm.latency.arn,
            aws_cloudwatch_metric_alarm.server-errors.arn,
            aws_cloudwatch_metric_alarm.ec2-cpu.arn,
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "Latencia (ms)"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = [
            [local.metrics_namespace, "Latency", { stat = "p50", label = "p50" }],
            [local.metrics_namespace, "Latency", { stat = "p90", label = "p90" }],
          ]
          annotations = { horizontal = [{ label = "Alarma p90", value = 1000 }] }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 3
        width  = 12
        height = 6
        properties = {
          title  = "Peticiones y errores 5xx (cada 5 min)"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            # Cada petición publica un dato de Latency: SampleCount = número de peticiones.
            [local.metrics_namespace, "Latency", { stat = "SampleCount", label = "Peticiones" }],
            [local.metrics_namespace, "ServerErrors", { stat = "Sum", label = "Errores 5xx" }],
          ]
          annotations = { horizontal = [{ label = "Alarma 5xx", value = 3 }] }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "CPU EC2 (%)"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.server.id, { label = "EC2" }],
          ]
          yAxis       = { left = { min = 0, max = 100 } }
          annotations = { horizontal = [{ label = "Alarma CPU", value = 80 }] }
        }
      },
      {
        # Solo contexto (sin alarma): ayuda a ver si la latencia o los 5xx vienen de la BD.
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "RDS: CPU (%) y conexiones"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.todo-db.identifier, { label = "CPU" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.todo-db.identifier, { label = "Conexiones", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}
