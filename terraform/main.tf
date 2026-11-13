terraform {
  # El tfstate vive en S3, nunca en el repo. El bucket se crea una sola vez con terraform/bootstrap.
  backend "s3" {
    bucket  = "to-do-list-tfstate-639932174029"
    key     = "to-do-list/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

# Subnets de la VPC default (en use1-az3 no hay t3.micro)
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone-id"
    values = ["use1-az1", "use1-az2", "use1-az4", "use1-az6"]
  }
}

### Ubuntu 24.04
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

### SSH KEY
# La pública está en el repo y la privada en el secret EC2_SSH_KEY (la usa el workflow de deploy).
resource "aws_key_pair" "todo-key" {
  key_name   = "${var.project_name}-key"
  public_key = file("${path.module}/deploy_key.pub")
}

### SECURITY GROUPS
resource "aws_security_group" "todo-sg" {
  name        = "${var.project_name}-sg"
  description = "SSH y puerto de la API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

# MySQL solo acepta conexiones desde la EC2
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
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  db_name                 = "todo"
  username                = "todo_admin"
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.todo-db.name
  vpc_security_group_ids  = [aws_security_group.rds-sg.id]
  backup_retention_period = 0    // sin backups: es un sandbox y así se crea más rápido
  skip_final_snapshot     = true // para que destroy no deje un snapshot
}

### SECRETS MANAGER: la app lee de aquí las credenciales de la BD
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}-db-credentials"
  recovery_window_in_days = 0 // se borra en el destroy y el nombre se puede volver a usar
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

### EC2
resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = sort(data.aws_subnets.default.ids)[0]
  key_name               = aws_key_pair.todo-key.key_name
  vpc_security_group_ids = [aws_security_group.todo-sg.id]

  # En el Learner Lab no se pueden crear roles IAM; LabInstanceProfile (LabRole) ya tiene
  # permiso para leer el secreto y mandar métricas a CloudWatch.
  iam_instance_profile = "LabInstanceProfile"

  # Primer boot: clona el repo, instala dependencias y deja la app corriendo con systemd.
  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y git python3-venv unzip

    git clone ${var.repo_url} /opt/todo/app
    python3 -m venv /opt/todo/venv
    /opt/todo/venv/bin/pip install -r /opt/todo/app/requirements.txt

    # Versión inicial para GET /version; el workflow de deploy la cambia con cada release
    echo "APP_VERSION=$(git -C /opt/todo/app describe --tags --always)" > /etc/todo.env
    chown -R ubuntu:ubuntu /opt/todo

    cat > /etc/systemd/system/todo.service <<SERVICE
    [Unit]
    Description=to-do-list API
    After=network-online.target

    [Service]
    User=ubuntu
    WorkingDirectory=/opt/todo/app
    Environment=AWS_REGION=${var.region}
    Environment=DB_SECRET_ID=${aws_secretsmanager_secret.db.name}
    EnvironmentFile=/etc/todo.env
    ExecStart=/opt/todo/venv/bin/gunicorn --bind 0.0.0.0:${var.app_port} --workers 2 app:app
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable --now todo
  EOF

  user_data_replace_on_change = true

  # Que la BD y el secreto ya existan cuando arranque la app
  depends_on = [aws_secretsmanager_secret_version.db]

  tags = {
    Name = "${var.project_name}-server"
  }
}
