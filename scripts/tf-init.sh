#!/bin/bash
# Crea (si no existe) el bucket S3 donde vive el tfstate e inicializa Terraform con ese backend.
# El nombre lleva el ID de la cuenta porque los nombres de bucket son únicos en todo S3.
# Uso, desde la raíz del repo: bash scripts/tf-init.sh [opciones extra de terraform init]
set -euo pipefail

REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="to-do-list-tfstate-$ACCOUNT_ID"

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Creando bucket $BUCKET para el tfstate"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  # Versionado: si un apply deja el state mal, se puede recuperar una versión anterior.
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
fi

terraform -chdir=terraform init -input=false -reconfigure \
  -backend-config="bucket=$BUCKET" "$@"
