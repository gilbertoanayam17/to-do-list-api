terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

### VPC default existente
data "aws_vpc" "default" {
  default = true
}

# Subnets default de la VPC (use1-az3 no ofrece t3.micro).
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
  filter {
    name   = "availability-zone-id"
    values = ["use1-az1", "use1-az2", "use1-az4", "use1-az6"]
  }
}

### AMI: Ubuntu 24.04 LTS oficial de Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

### SSH KEY (creada por Terraform)
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "todo-key" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

### SECURITY GROUP
resource "aws_security_group" "todo-sg" {
  name        = "${var.project_name}-sg"
  description = "SSH y puerto de la API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "API to-do list"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

### SECURITY GROUP de RDS: MySQL solo acepta conexiones que vengan del SG de la EC2
resource "aws_security_group" "rds-sg" {
  name        = "${var.project_name}-rds-sg"
  description = "MySQL solo desde la EC2 de la API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL desde la EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.todo-sg.id]
  }
}

### RDS (MySQL)
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?" // RDS no acepta / @ " ni espacios
}

resource "aws_db_subnet_group" "todo-db" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "todo-db" {
  identifier              = "${var.project_name}-db"
  engine                  = "mysql"
  engine_version          = "8.4"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp2"
  db_name                 = var.db_name
  username                = var.db_username
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.todo-db.name
  vpc_security_group_ids  = [aws_security_group.rds-sg.id]
  publicly_accessible     = false
  backup_retention_period = 0
  skip_final_snapshot     = true // para que terraform destroy no deje un snapshot
  apply_immediately       = true

  tags = {
    Name = "${var.project_name}-db"
  }
}

### SECRETS MANAGER: credenciales de la BD fuera del código
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}-db-credentials"
  recovery_window_in_days = 0 // borrado inmediato en destroy; si no, el nombre queda apartado 7+ días
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host     = aws_db_instance.todo-db.address
    port     = aws_db_instance.todo-db.port
    username = aws_db_instance.todo-db.username
    password = random_password.db.result
    dbname   = aws_db_instance.todo-db.db_name
  })
}

### IAM: permiso para que la EC2 lea el secreto
# En el Learner Lab no se pueden crear roles; se usa el instance profile existente
# (LabInstanceProfile -> LabRole). En una cuenta normal se crearía un aws_iam_role que
# confíe en ec2.amazonaws.com, con una policy que permita secretsmanager:GetSecretValue
# sobre este secreto, y un aws_iam_instance_profile con ese rol.
data "aws_iam_instance_profile" "lab" {
  name = var.instance_profile_name
}

### EC2
resource "aws_instance" "server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  key_name                    = aws_key_pair.todo-key.key_name
  vpc_security_group_ids      = [aws_security_group.todo-sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = data.aws_iam_instance_profile.lab.name

  # Script que corre una sola vez, como root, en el primer boot:
  # clona el repo, instala dependencias y deja la app como servicio de systemd.
  # Solo recibe el NOMBRE del secreto; la contraseña nunca pasa por user_data.
  user_data = templatefile("${path.module}/user_data.sh", {
    repo_url     = var.repo_url
    repo_branch  = var.repo_branch
    app_port     = var.app_port
    region       = var.region
    db_secret_id = aws_secretsmanager_secret.db.name
  })
  # Si cambia el script, Terraform reemplaza la instancia para que vuelva a correr.
  user_data_replace_on_change = true

  # La app lee el secreto al arrancar: la BD y el secreto deben existir antes.
  depends_on = [aws_secretsmanager_secret_version.db]

  tags = {
    Name = "${var.project_name}-server"
  }
}
