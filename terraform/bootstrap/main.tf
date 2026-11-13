# Crea el bucket S3 donde vive el tfstate del proyecto. Se corre UNA sola vez por cuenta, en local:
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply
# Va aparte porque el bucket tiene que existir antes del terraform init del proyecto.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# El nombre lleva el ID de la cuenta porque los nombres de bucket son únicos en todo S3.
resource "aws_s3_bucket" "tfstate" {
  bucket = "to-do-list-tfstate-${data.aws_caller_identity.current.account_id}"
}

# Versionado: si un apply deja mal el state, se puede regresar a una versión anterior.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

output "bucket" {
  description = "Nombre que va en el backend de terraform/main.tf"
  value       = aws_s3_bucket.tfstate.bucket
}
