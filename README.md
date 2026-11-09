# to-do-list-api

API sencilla de to-do list en Python (Flask). Las tareas se guardan en MySQL (Amazon RDS) y las
credenciales se leen de AWS Secrets Manager. Toda la infraestructura sale de Terraform: ver
[terraform/](terraform/).

| Método | Ruta       | Descripción                         |
|--------|------------|-------------------------------------|
| GET    | `/tasks`   | Regresa la lista de tareas          |
| POST   | `/tasks`   | Agrega una tarea `{"tarea": "..."}` |
| GET    | `/version` | Versión desplegada `{"version": "v1.0.0"}` |
| GET    | `/health`  | Estado: BD (`SELECT 1`), versión y timestamp. 200 si la BD responde, 503 si no |

```json
{"status": "OK", "database": "OK", "version": "v1.1.0", "timestamp": "2026-11-05T23:03:08+00:00"}
```

## Configuración

La app no tiene credenciales en el código. En la primera petición lee el secreto indicado en
`DB_SECRET_ID` (JSON con `host`, `port`, `username`, `password`, `dbname`) usando el rol IAM de
la instancia, y crea la tabla `tasks` si no existe.

| Variable       | Ejemplo                     |
|----------------|-----------------------------|
| `DB_SECRET_ID` | `to-do-list-db-credentials` |
| `AWS_REGION`   | `us-east-1`                 |
| `APP_VERSION`  | `v1.0.0` (en la EC2 vive en `/etc/todo.env`; default `dev`) |

```bash
curl http://<IP>:8000/tasks
curl -X POST http://<IP>:8000/tasks \
  -H "Content-Type: application/json" \
  -d '{"tarea": "resolver actividad en equipo"}'
curl http://<IP>:8000/version
```

## Pruebas

Las pruebas reemplazan la capa de base de datos (`fetch_tasks`/`insert_task`) por una lista, así
que no necesitan AWS ni MySQL:

```bash
pip install -r requirements-dev.txt
pytest -v
```

## CI/CD (GitHub Actions)

| Workflow | Disparador | Qué hace |
|----------|------------|----------|
| [CI](.github/workflows/ci.yml) | PR hacia `main` | **Continuous Integration**: corre `pytest`. La regla de `main` exige el check `tests`, así que no se puede hacer merge si fallan |
| [Release](.github/workflows/release.yml) | push de tag `v#.#.#` | **Continuous Delivery**: corre las pruebas, crea un release con el repo en zip y llama a Deploy |
| [Deploy](.github/workflows/deploy.yml) | lo llama Release, o a mano con un tag | **Continuous Deployment**: por SSH, la EC2 descarga el zip del release ([scripts/deploy.sh](scripts/deploy.sh)), reinicia la app y verifica `/version`; si no responde, regresa a la versión anterior |
| [Infra - apply / destroy](.github/workflows/infra-apply.yml) | a mano | Terraform con el tfstate en S3 (ver [terraform/](terraform/)) |
| [Monitor](.github/workflows/monitor.yml) | `schedule` cada 5 min (o a mano) | `GET /health`; si no responde 200 el run falla y GitHub avisa por correo |

El monitor solo corre desde `main`, y GitHub puede retrasar los runs programados. Cuando el lab
se apaga la EC2 deja de responder y el monitor falla cada 5 minutos: desactívalo en
**Actions → Monitor → ⋯ → Disable workflow** cuando termines.

Deploy se encadena desde Release en lugar de usar `on: release`, porque un release creado con
`GITHUB_TOKEN` no dispara otros workflows.

Publicar una versión:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Monitoreo (CloudWatch)

### Estrategia

Queremos enterarnos de tres cosas antes que los usuarios: que la API **falla**, que está
**lenta**, o que el servidor se está **quedando sin recursos**.

| Métrica | Origen | Alarma (→ SNS → correo) | Por qué ese umbral |
|---------|--------|-------------------------|--------------------|
| `ToDoListApi/ServerErrors` | App (`put_metric_data`): 1 si la respuesta es 5xx, 0 si no | `Sum >= 3` en 5 min | Un 5xx es falla nuestra (BD caída, excepción). 3 en 5 min ya no es un error aislado |
| `ToDoListApi/Latency` (ms) | App (`put_metric_data`): duración de cada petición | `p90 > 1000 ms` en 3 de 5 min | Normalmente tarda decenas de ms; > 1 s es una API lenta. p90 porque el promedio esconde las peticiones lentas |
| `AWS/EC2/CPUUtilization` | AWS (cada 5 min) | `Average > 80%` 2 periodos de 5 min | t3.micro es burstable: CPU alta sostenida gasta los créditos y la instancia se frena |

Las alarmas avisan también cuando regresan a OK. Sin tráfico no hay datos de las métricas
propias, y eso se trata como "no rompe el umbral" (`treat_missing_data = notBreaching`).

### Cómo se mandan las métricas

En [app.py](app.py), `after_request` arma las dos métricas de cada petición y las manda en una
sola llamada a `put_metric_data` (namespace `ToDoListApi`). La llamada se hace con
`response.call_on_close`, cuando gunicorn ya entregó la respuesta, así el cliente no espera a
CloudWatch. Si CloudWatch falla, solo se escribe un warning en el log: el monitoreo nunca tumba la
API. La EC2 se autentica con `LabInstanceProfile`, igual que con Secrets Manager.

Como cada petición publica un dato de `Latency`, su `SampleCount` es el número de peticiones, y el
`Average` de `ServerErrors` es la tasa de error, sin métricas extra.

### Infraestructura

Todo sale de Terraform ([terraform/monitoring.tf](terraform/monitoring.tf)): el tópico SNS con la
suscripción por correo, las 3 alarmas y el dashboard `to-do-list` (alarmas, latencia, peticiones
y errores, CPU de la EC2 y, como contexto, CPU y conexiones de RDS). El correo viene del secret
`ALERT_EMAIL`. Después del apply llega un correo de AWS para **confirmar la suscripción**; sin eso
no llegan las alertas (en cada sandbox nuevo hay que volver a confirmar).

### Probar las alarmas

```bash
# Forzar el estado de una alarma para probar el correo (vuelve sola en la siguiente evaluación)
aws cloudwatch set-alarm-state --alarm-name to-do-list-errores-5xx \
  --state-value ALARM --state-reason "Prueba de notificación"

# Generar tráfico para ver las métricas en el dashboard
for i in $(seq 1 50); do curl -s -o /dev/null http://<IP>:8000/tasks; done
```

Para provocar errores y latencia reales basta con detener la BD (**RDS → Actions → Stop**): `/tasks`
responde 500 y `/health` 503 después del `connect_timeout` de 5 s.

El workflow Monitor sigue revisando desde fuera (si la EC2 está apagada la app no puede mandar
métricas, pero GitHub sí nota que no responde).

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
