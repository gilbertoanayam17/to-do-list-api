### SNS: las 3 alarmas mandan correo a este tópico
resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms"
}

# AWS manda un correo para confirmar la suscripción; sin confirmarla no llegan las alertas.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

### Alarma 1 (métrica nativa de AWS): CPU de la EC2
# La t3.micro es burstable: si pasa mucho tiempo arriba de 80% se acaba los créditos y se alenta.
resource "aws_cloudwatch_metric_alarm" "ec2-cpu" {
  alarm_name          = "${var.project_name}-ec2-cpu-alta"
  alarm_description   = "CPU de la EC2 arriba de 80% durante 10 minutos"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.server.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

### Alarma 2 (métrica propia): errores al leer o escribir en RDS
# En operación normal no debería haber ninguno. 3 en 5 minutos ya no es un error aislado
# (el health check pega a /health hasta 3 veces cuando falla).
resource "aws_cloudwatch_metric_alarm" "db-errors" {
  alarm_name          = "${var.project_name}-errores-rds"
  alarm_description   = "3 o más errores de RDS en 5 minutos"
  namespace           = "ToDoListApi"
  metric_name         = "DatabaseErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" // sin errores no se manda nada, y eso está bien
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

### Alarma 3 (métrica propia): latencia de la API
# Normalmente una petición tarda decenas de ms. p90 arriba de 1 s durante 3 minutos seguidos
# quiere decir que la API está lenta para casi todos (p. ej. RDS saturada o sin responder).
resource "aws_cloudwatch_metric_alarm" "latency" {
  alarm_name          = "${var.project_name}-latencia-alta"
  alarm_description   = "p90 de la latencia arriba de 1 s durante 3 minutos"
  namespace           = "ToDoListApi"
  metric_name         = "Latency"
  extended_statistic  = "p90"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching" // sin tráfico no hay datos
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

### DASHBOARD: la configuración está en alerting/cloudwatch-dashboard.json
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project_name
  dashboard_body = templatefile("${path.module}/../alerting/cloudwatch-dashboard.json", {
    region          = var.region
    instance_id     = aws_instance.server.id
    alarm_cpu       = aws_cloudwatch_metric_alarm.ec2-cpu.arn
    alarm_db_errors = aws_cloudwatch_metric_alarm.db-errors.arn
    alarm_latency   = aws_cloudwatch_metric_alarm.latency.arn
  })
}
