variable "region" {
  description = "Región de AWS donde se crearán los recursos"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto, se usa como prefijo en los recursos"
  type        = string
  default     = "to-do-list"
}

variable "instance_type" {
  description = "Tamaño de la instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidr" {
  description = "CIDR con acceso SSH a la instancia"
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_port" {
  description = "Puerto en el que escucha la API"
  type        = number
  default     = 8000
}

variable "repo_url" {
  description = "Repositorio público que user_data clona en la instancia"
  type        = string
  default     = "https://github.com/gilbertoanayam17/to-do-list-api.git"
}

variable "repo_branch" {
  description = "Rama del repositorio que se despliega"
  type        = string
  default     = "main"
}

variable "instance_profile_name" {
  description = "Instance profile con permiso para leer el secreto (LabInstanceProfile en AWS Academy)"
  type        = string
  default     = "LabInstanceProfile"
}

variable "db_instance_class" {
  description = "Tamaño de la instancia RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "todo"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos"
  type        = string
  default     = "todo_admin"
}
