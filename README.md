# to-do-list-api

API sencilla de to-do list en Python (Flask). Las tareas se guardan en MySQL (Amazon RDS) y las
credenciales se leen de AWS Secrets Manager. Toda la infraestructura sale de Terraform: ver
[terraform/](terraform/).

| Método | Ruta     | Descripción                     |
|--------|----------|---------------------------------|
| GET    | `/tasks` | Regresa la lista de tareas      |
| POST   | `/tasks` | Agrega una tarea `{"tarea": "..."}` |

## Configuración

La app no tiene credenciales en el código. Al arrancar lee el secreto indicado en
`DB_SECRET_ID` (JSON con `host`, `port`, `username`, `password`, `dbname`) usando el rol IAM de
la instancia, y crea la tabla `tasks` si no existe.

| Variable       | Ejemplo                     |
|----------------|-----------------------------|
| `DB_SECRET_ID` | `to-do-list-db-credentials` |
| `AWS_REGION`   | `us-east-1`                 |

```bash
curl http://<IP>:8000/tasks
curl -X POST http://<IP>:8000/tasks \
  -H "Content-Type: application/json" \
  -d '{"tarea": "resolver actividad en equipo"}'
```

## Parte 2: preguntas

**¿Cómo damos permiso para que un servicio de AWS acceda a otro?**
Con **IAM roles**: el servicio asume un rol cuyas policies dicen qué acciones puede hacer
sobre qué recursos. En EC2 el rol se asocia a la instancia con un **instance profile** y el SDK
(boto3) obtiene credenciales temporales automáticamente, sin llaves en el código. A nivel de
red, además, los **Security Groups** deciden quién puede conectarse: el SG de RDS solo acepta
el puerto 3306 desde el SG de la EC2.

**¿Qué servicio usarían para que la app no tenga las credenciales de RDS hardcodeadas?**
**AWS Secrets Manager** (alternativa: SSM Parameter Store con `SecureString`). La app solo
conoce el nombre del secreto.

**¿Qué hay que agregar a Terraform?**
- `aws_db_instance` (MySQL) + `aws_db_subnet_group`
- `aws_security_group` para RDS (3306 solo desde el SG de la EC2)
- `random_password` + `aws_secretsmanager_secret` + `aws_secretsmanager_secret_version`
- Un instance profile en la EC2 (`iam_instance_profile`) con permiso de
  `secretsmanager:GetSecretValue`. En el Learner Lab no se pueden crear roles, así que se usa
  `LabInstanceProfile`; en una cuenta normal serían `aws_iam_role`, `aws_iam_role_policy` y
  `aws_iam_instance_profile`.
- `user_data` que pase `DB_SECRET_ID` a la app.

## Despliegue manual en EC2 (actividad original)

1. Crear una instancia `t3.micro` con Ubuntu y un Key Pair (`.pem`).
2. Copiar el código: `scp -i llave.pem app.py requirements.txt ubuntu@<IP>:~/`
3. En la instancia:
   `sudo apt update && sudo apt install -y python3-venv && python3 -m venv venv && venv/bin/pip install -r requirements.txt && venv/bin/python app.py`

**¿Pueden usar el servicio? ¿Qué falta?** Desde fuera no responde en un inicio:

- El **Security Group** solo abre el puerto 22 (SSH); hay que agregar una regla de entrada para el puerto **8000**.
- La app debe escuchar en `0.0.0.0`, no en `127.0.0.1`, para aceptar conexiones externas.
- El proceso muere al cerrar la sesión SSH: hace falta un gestor de procesos (systemd) y un servidor WSGI de producción (gunicorn) en lugar del servidor de desarrollo de Flask.
- Las tareas viven en memoria: se pierden al reiniciar y no se comparten entre varias instancias → hace falta una base de datos.
- El despliegue es manual (consola + `scp`) y no es reproducible → infraestructura como código.
