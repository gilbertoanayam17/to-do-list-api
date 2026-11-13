output "server_public_ip" {
  description = "IP pública de la EC2 (va en el secret EC2_HOST)"
  value       = aws_instance.server.public_ip
}

output "api_url" {
  description = "URL del endpoint /tasks"
  value       = "http://${aws_instance.server.public_ip}:${var.app_port}/tasks"
}

output "dashboard_url" {
  description = "Dashboard de CloudWatch"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}
