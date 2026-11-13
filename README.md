# to-do-list-api

API de tareas pendientes en Python (Flask), desplegada en una EC2 con las tareas guardadas en
RDS (MySQL). Toda la infraestructura sale de Terraform y el camino de un cambio hasta producción
(pruebas, release y deploy) está automatizado con GitHub Actions. La observabilidad está en
CloudWatch.

| Endpoint | Descripción |
|----------|-------------|
| `GET /tasks` | Lista de tareas |
| `POST /tasks` | Crea una tarea: `{"title": "...", "done": false}` (`done` es opcional) |
| `GET /version` | Versión desplegada (variable de ambiente `APP_VERSION`) |
| `GET /health` | Conexión a la BD (`OK`/`FAIL`), versión y timestamp. 200 si la BD responde, 503 si no |

```bash
curl -X POST http://<ip-de-tu-ec2>:8000/tasks \
  -H "Content-Type: application/json" \
  -d '{"title": "estudiar para el examen de desarrollo en la nube", "done": false}'

curl http://<ip-de-tu-ec2>:8000/tasks
curl http://<ip-de-tu-ec2>:8000/health
```

## Estructura

```
├── app.py                        # la API
├── requirements.txt
├── tests/test_app.py             # pruebas unitarias (no necesitan AWS)
├── .github/workflows/
│   ├── provision.yml             # terraform apply (manual)
│   ├── destroy.yml               # terraform destroy (manual)
│   ├── ci.yml                    # pruebas en cada PR
│   ├── release.yml               # tag v#.#.# -> release con el repo en zip
│   ├── deploy.yml                # release -> EC2
│   └── health-check.yml          # GET /health cada 5 min
├── terraform/
│   ├── main.tf                   # EC2, Security Groups, Key Pair, RDS, Secrets Manager, user_data
│   ├── monitoring.tf             # SNS, 3 alarmas y dashboard
│   ├── variables.tf / outputs.tf
│   ├── deploy_key.pub            # llave pública SSH (la privada está en GitHub Secrets)
│   └── bootstrap/main.tf         # bucket S3 del tfstate (una sola vez)
└── alerting/cloudwatch-dashboard.json
```

## Correr en local

```bash
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt pytest
python -m pytest -v
```

La app necesita RDS y Secrets Manager, así que donde realmente corre es en la EC2. Las pruebas
reemplazan la base de datos por una lista y no mandan métricas, así que corren sin AWS.

## Infraestructura (Terraform)

`terraform/main.tf` crea la EC2 (t3.micro, Ubuntu 24.04), su Security Group (22 y 8000), el Key
Pair, la base de datos RDS con su propio Security Group (3306 solo desde la EC2) y el secreto en
Secrets Manager con las credenciales. La app lee el secreto en tiempo de ejecución con el rol de
la instancia (`LabInstanceProfile`), así que no hay contraseñas en el código.

El `user_data` de la EC2 clona este repo, instala las dependencias y deja la app corriendo como
servicio de systemd con gunicorn, sin entrar por SSH.

### tfstate en S3

El sandbox se reinicia seguido, así que el tfstate vive en el bucket
`to-do-list-tfstate-<id-de-la-cuenta>` (con versionado) y nunca en el repo. El bucket se crea una
sola vez por cuenta, en local:

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
```

### Secrets del repo

**Settings → Secrets and variables → Actions**:

| Secret | Qué es |
|--------|--------|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Credenciales del Learner Lab (AWS Details). Cambian con cada sesión |
| `EC2_HOST` | IP de la EC2. Cambia con cada Provision |
| `EC2_SSH_KEY` | Llave privada SSH que corresponde a `terraform/deploy_key.pub` |
| `ALERT_EMAIL` | Correo que recibe las alarmas |

### Crear y destruir

- **Crear:** Actions → **Provision** → Run workflow. RDS tarda ~5 min; al final el resumen del
  run muestra la IP (cópiala a `EC2_HOST`) y la URL del dashboard. Confirma el correo de
  suscripción de SNS que te llega de AWS.
- **Destruir:** Actions → **Destroy** → Run workflow, escribiendo `destroy` para confirmar.

También se puede desde local con `terraform -chdir=terraform init` y `apply`/`destroy`
(pide el correo de las alarmas o se pasa con `TF_VAR_alert_email`).

## CI/CD

1. **CI:** cada PR hacia `main` corre las pruebas. `main` tiene un ruleset que exige el check
   `tests` y un PR para hacer merge, así que un cambio que rompe las pruebas no entra.
2. **Release (Continuous Delivery):** al empujar un tag `v#.#.#` se corren las pruebas y se crea
   un release en GitHub con el repo en zip.
   ```bash
   git tag v1.3.0
   git push origin v1.3.0
   ```
3. **Deploy (Continuous Deployment):** con el release publicado, la EC2 descarga el zip por SSH,
   instala dependencias, actualiza `APP_VERSION` y reinicia el servicio. Al final el workflow
   confirma con `GET /version` que quedó la versión nueva. Release llama a Deploy directamente
   porque un release creado con `GITHUB_TOKEN` no dispara workflows con `on: release`; Deploy
   también se puede correr a mano con un tag.
4. **Health check:** cada 5 minutos revisa `GET /health` y falla si no responde 200. Cuando
   termines o se apague el lab, desactívalo (Actions → Health check → ⋯ → Disable workflow).

## Observabilidad (CloudWatch)

| Métrica | Tipo | Alarma (→ SNS → correo) | Por qué |
|---------|------|-------------------------|---------|
| `AWS/EC2 CPUUtilization` | Nativa | Promedio > 80% durante 10 min | La t3.micro es burstable: si se queda arriba mucho tiempo se gasta los créditos y se alenta |
| `ToDoListApi/DatabaseErrors` | Propia (`put_metric_data`) | Suma ≥ 3 en 5 min | Cada lectura o escritura a RDS que falla manda un 1. En operación normal no debería haber ninguno |
| `ToDoListApi/Latency` (ms) | Propia (`put_metric_data`) | p90 > 1000 ms durante 3 min | Normalmente una petición tarda decenas de ms. Si el p90 pasa de 1 s, la API está lenta para casi todos |

- Las alarmas, el tópico SNS y la suscripción están en [terraform/monitoring.tf](terraform/monitoring.tf).
- El dashboard está en [alerting/cloudwatch-dashboard.json](alerting/cloudwatch-dashboard.json).
  Terraform lo crea con los IDs reales y muestra las alarmas y las 3 métricas.

**Validar la métrica de errores de RDS:** detén la base de datos (RDS → Actions → Stop
temporarily) y pega algunas veces a `/tasks` o `/health`. Cada petición falla, `DatabaseErrors`
sube en el dashboard y la alarma manda correo. La latencia también sube, porque cada intento espera
el `connect_timeout` de 5 s.
