# Infraestructura con Terraform

Provisiona en AWS (default VPC, `us-east-1`):

- Un **Key Pair** generado por Terraform (`tls_private_key` + `aws_key_pair`)
- Un **Security Group** con SSH (22) y el puerto de la API (8000)
- Una **instancia EC2** `t3.micro` con Ubuntu 24.04

El despliegue también sale de Terraform: [`user_data.sh`](user_data.sh) se ejecuta en el primer
boot, clona este repo, instala dependencias en un venv y registra la app como servicio de
systemd (gunicorn), así arranca sola en cada boot.

## Requisitos

- Terraform instalado (`terraform -v`)
- Credenciales del Learner Lab en `~/.aws/credentials`
- El código ya subido al repo público (user_data lo clona de GitHub)

## Flujo de Terraform

```bash
terraform init       # descarga los providers
terraform validate   # revisa la sintaxis
terraform plan       # muestra qué se va a crear, sin crear nada
terraform apply      # crea la infraestructura
```

La app tarda 1–2 minutos después del `apply` en responder (apt + pip en el boot).

```bash
curl $(terraform output -raw api_url)
curl -X POST $(terraform output -raw api_url) \
  -H "Content-Type: application/json" \
  -d '{"tarea": "resolver actividad en equipo"}'
```

## SSH

```bash
terraform output -raw private_key_pem > ~/.ssh/todo-key.pem
chmod 400 ~/.ssh/todo-key.pem
ssh -i ~/.ssh/todo-key.pem ubuntu@$(terraform output -raw server_public_ip)

# en la instancia
sudo cat /var/log/user-data.log     # salida del script de arranque
systemctl status todo               # estado de la app
```

## Destruir

```bash
terraform destroy
```

## tfstate

`terraform.tfstate` **no se sube al repo** (está en `.gitignore`): es lo que Terraform usa para saber
qué recursos existen en la nube y contiene datos sensibles, como la llave privada SSH.
