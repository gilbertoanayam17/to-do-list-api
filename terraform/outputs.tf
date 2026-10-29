output "server_public_ip" {
  description = "IP pública de la instancia EC2"
  value       = aws_instance.server.public_ip
}

output "server_instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.server.id
}

output "api_url" {
  description = "URL del endpoint /tasks"
  value       = "http://${aws_instance.server.public_ip}:${var.app_port}/tasks"
}

output "rds_endpoint" {
  description = "Endpoint de la base de datos (solo accesible desde la EC2)"
  value       = aws_db_instance.todo-db.endpoint
}

output "db_secret_name" {
  description = "Secreto de Secrets Manager con las credenciales de la BD"
  value       = aws_secretsmanager_secret.db.name
}

output "private_key_pem" {
  description = "Llave privada para conectarse a la EC2 por SSH"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true // no se va a imprimir
}
