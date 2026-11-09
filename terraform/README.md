# Infraestructura con Terraform

Provisiona en AWS (default VPC, `us-east-1`):

- Un **Key Pair** con la llave pública [`deploy_key.pub`](deploy_key.pub) (la privada está en el secret `EC2_SSH_KEY`)
- Un **Security Group** con SSH (22) y el puerto de la API (8000)
- Una **instancia EC2** `t3.micro` con Ubuntu 24.04 y el instance profile `LabInstanceProfile`
- Una **base de datos RDS** MySQL `db.t3.micro`, privada, con su subnet group
- Un **Security Group para RDS** que solo acepta 3306 desde el SG de la EC2
- Un **secreto en Secrets Manager** con las credenciales (password generado con `random_password`)
- **Monitoreo** ([`monitoring.tf`](monitoring.tf)): tópico **SNS** con suscripción por correo, 3
  **alarmas de CloudWatch** (errores 5xx, latencia, CPU de la EC2) y un **dashboard**. Ver
  [Monitoreo](../README.md#monitoreo-cloudwatch)

El despliegue inicial también sale de Terraform: [`user_data.sh`](user_data.sh) se ejecuta en el
primer boot, clona este repo en `/opt/todo/app`, instala dependencias en `/opt/todo/venv` y
registra la app como servicio de systemd (gunicorn), así arranca sola en cada boot. A la app solo
le pasa el nombre del secreto. Las versiones siguientes llegan por el workflow de deploy.

## Deploy de infra con un botón (GitHub Actions)

El sandbox del Learner Lab se reinicia, así que la infraestructura se levanta desde GitHub:

| Workflow | Qué hace |
|----------|----------|
| [Infra - apply](../.github/workflows/infra-apply.yml) | `init` + `plan` + `apply`; al final muestra la IP en el resumen del run |
| [Infra - destroy](../.github/workflows/infra-destroy.yml) | `destroy` (pide escribir `destroy` para confirmar) |

Los dos se disparan a mano desde **Actions → (workflow) → Run workflow**.

Secrets del repo (**Settings → Secrets and variables → Actions**):

| Secret | Cuándo se actualiza |
|--------|---------------------|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Cada sandbox nuevo (Learner Lab → AWS Details) |
| `EC2_HOST` | Después de cada apply (IP que muestra el resumen del run) |
| `EC2_SSH_KEY` | Una sola vez: contenido de la llave privada `~/.ssh/to-do-list-deploy` |
| `ALERT_EMAIL` | Una sola vez: correo que recibe las alarmas (variable `alert_email`) |

## ¿Dónde vive el tfstate?

En un **bucket S3** (`to-do-list-tfstate-<ID de la cuenta>`) con versionado. Así el runner de
GitHub, que empieza vacío en cada run, sabe qué recursos existen, y destroy puede borrar lo que creó
apply. [`scripts/tf-init.sh`](../scripts/tf-init.sh) crea el bucket si no existe (sandbox nuevo) y
corre `terraform init` con ese backend. En CI se activa `use_lockfile` para que dos runs no
escriban el state al mismo tiempo.

El bucket no lo administra Terraform, por eso sobrevive al `destroy`.

## Correr en local

```bash
bash scripts/tf-init.sh               # desde la raíz del repo
export TF_VAR_alert_email=tu@correo.com
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

RDS tarda ~5–10 minutos en crearse; la EC2 se crea después (espera al secreto) y la app tarda
1–2 minutos más en responder (apt + pip en el boot).

```bash
curl http://<IP>:8000/tasks
curl -X POST http://<IP>:8000/tasks \
  -H "Content-Type: application/json" \
  -d '{"tarea": "resolver actividad en equipo"}'
```

## SSH

```bash
ssh -i ~/.ssh/to-do-list-deploy ubuntu@<IP>

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

## tfstate

`terraform.tfstate` **no se sube al repo** (está en `.gitignore`): es lo que Terraform usa para saber
qué recursos existen en la nube y contiene datos sensibles, como el password de la base de datos.
