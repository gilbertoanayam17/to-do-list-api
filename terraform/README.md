# Infraestructura con Terraform

Provisiona en AWS (default VPC, `us-east-1`):

- Un **Key Pair** generado por Terraform (`tls_private_key` + `aws_key_pair`)
- Un **Security Group** con SSH (22) y el puerto de la API (8000)
- Una **instancia EC2** `t3.micro` con Ubuntu 24.04 y el instance profile `LabInstanceProfile`
- Una **base de datos RDS** MySQL `db.t3.micro`, privada, con su subnet group
- Un **Security Group para RDS** que solo acepta 3306 desde el SG de la EC2
- Un **secreto en Secrets Manager** con las credenciales (password generado con `random_password`)

El despliegue también sale de Terraform: [`user_data.sh`](user_data.sh) se ejecuta en el primer
boot, clona este repo, instala dependencias en un venv y registra la app como servicio de
systemd (gunicorn), así arranca sola en cada boot. A la app solo le pasa el nombre del secreto.

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

RDS tarda ~5–10 minutos en crearse; la EC2 se crea después (espera al secreto) y la app tarda
1–2 minutos más en responder (apt + pip en el boot).

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

## Consultar la base de datos

RDS no es pública: hay que entrar desde la EC2. `user_data` instala el atajo `todo-db`, que lee
las credenciales de Secrets Manager y abre `mysql`:

```bash
todo-db -e "SELECT * FROM tasks;"
todo-db                              # shell interactivo
```

## Destruir

```bash
terraform destroy
```

## tfstate

`terraform.tfstate` **no se sube al repo** (está en `.gitignore`): es lo que Terraform usa para saber
qué recursos existen en la nube y contiene datos sensibles, como la llave privada SSH y el
password de la base de datos.
