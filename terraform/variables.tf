variable "region" {
  description = "Región de AWS donde se crean los recursos"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo para los nombres de los recursos"
  type        = string
  default     = "to-do-list"
}

variable "instance_type" {
  description = "Tamaño de la instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "app_port" {
  description = "Puerto de la API"
  type        = number
  default     = 8000
}

variable "repo_url" {
  description = "Repositorio que clona user_data"
  type        = string
  default     = "https://github.com/gilbertoanayam17/to-do-list-api.git"
}

variable "alert_email" {
  description = "Correo que recibe las alarmas (en GitHub Actions sale del secret ALERT_EMAIL)"
  type        = string
}
