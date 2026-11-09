import json
import os
import time
from datetime import datetime, timezone

import boto3
import pymysql
from botocore.config import Config
from flask import Flask, g, jsonify, request

app = Flask(__name__)

# Namespace de las métricas propias en CloudWatch (los que empiezan con AWS/ son reservados).
METRICS_NAMESPACE = "ToDoListApi"
CLOUDWATCH = None

# Credenciales de la BD; se cargan en la primera conexión, no al importar,
# para que las pruebas puedan importar la app sin AWS.
DB = None
# Aparte de DB: si la primera conexión falla, la tabla se crea en el siguiente intento.
TABLE_READY = False


def load_db_credentials():
    # Las credenciales viven en Secrets Manager, no en el código.
    # boto3 se autentica con el rol IAM de la instancia (instance profile).
    client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    secret = client.get_secret_value(SecretId=os.environ["DB_SECRET_ID"])
    return json.loads(secret["SecretString"])


def get_connection():
    global DB, TABLE_READY
    if DB is None:
        DB = load_db_credentials()

    conn = pymysql.connect(
        host=DB["host"],
        port=int(DB["port"]),
        user=DB["username"],
        password=DB["password"],
        database=DB["dbname"],
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
        connect_timeout=5,  # que /health reporte FAIL rápido si la BD no responde
    )
    if not TABLE_READY:
        init_db(conn)
        TABLE_READY = True
    return conn


def init_db(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id INT AUTO_INCREMENT PRIMARY KEY,
                tarea VARCHAR(255) NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )


def fetch_tasks():
    with get_connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT id, tarea FROM tasks ORDER BY id")
        return cur.fetchall()


def insert_task(tarea):
    with get_connection() as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO tasks (tarea) VALUES (%s)", (tarea,))
        return cur.lastrowid


def check_db():
    with get_connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT 1")


def app_version():
    # systemd la carga de /etc/todo.env; cada deploy la actualiza con el tag del release.
    return os.environ.get("APP_VERSION", "dev")


def put_metrics(metric_data):
    global CLOUDWATCH
    if CLOUDWATCH is None:
        # Timeouts cortos: si CloudWatch no responde, el worker no se queda colgado 60 s (default).
        CLOUDWATCH = boto3.client(
            "cloudwatch",
            region_name=os.environ.get("AWS_REGION", "us-east-1"),
            config=Config(connect_timeout=2, read_timeout=2, retries={"max_attempts": 2}),
        )
    CLOUDWATCH.put_metric_data(Namespace=METRICS_NAMESPACE, MetricData=metric_data)


def send_metrics(metric_data):
    # El monitoreo nunca debe tumbar la API: si falla el envío, solo se registra en el log.
    try:
        put_metrics(metric_data)
    except Exception:
        app.logger.warning("No se pudieron enviar métricas a CloudWatch", exc_info=True)


@app.before_request
def start_timer():
    g.start = time.perf_counter()


@app.after_request
def record_metrics(response):
    # Corre también para los 500 de excepciones no manejadas (Flask arma la respuesta y luego
    # llama a after_request), así que los errores de la BD en /tasks sí se cuentan.
    latency_ms = (time.perf_counter() - g.get("start", time.perf_counter())) * 1000
    metric_data = [
        {"MetricName": "Latency", "Value": latency_ms, "Unit": "Milliseconds"},
        # 1 por cada 5xx y 0 si no: Sum = número de errores, Average = tasa de error,
        # SampleCount = número de peticiones.
        {"MetricName": "ServerErrors", "Value": 1 if response.status_code >= 500 else 0, "Unit": "Count"},
    ]
    # call_on_close: put_metric_data se llama cuando gunicorn ya mandó la respuesta,
    # así el cliente no espera la llamada a CloudWatch.
    response.call_on_close(lambda: send_metrics(metric_data))
    return response


@app.get("/version")
def version():
    return jsonify({"version": app_version()})


@app.get("/health")
def health():
    try:
        check_db()
        database = "OK"
    except Exception:
        app.logger.exception("Health check: la base de datos no responde")
        database = "FAIL"

    body = {
        "status": "OK" if database == "OK" else "FAIL",
        "database": database,
        "version": app_version(),
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    # 503 si la BD falla: así el monitor (que exige 200) detecta el problema.
    return jsonify(body), 200 if database == "OK" else 503


@app.get("/tasks")
def list_tasks():
    return jsonify(fetch_tasks())


@app.post("/tasks")
def add_task():
    body = request.get_json(silent=True) or {}
    tarea = body.get("tarea")
    if not isinstance(tarea, str) or not tarea.strip():
        return jsonify({"error": "Se requiere el campo 'tarea' (texto no vacio)"}), 400
    if len(tarea.strip()) > 255:
        return jsonify({"error": "'tarea' no puede pasar de 255 caracteres"}), 400

    tarea = tarea.strip()
    return jsonify({"id": insert_task(tarea), "tarea": tarea}), 201


if __name__ == "__main__":
    # 0.0.0.0 para aceptar conexiones desde fuera de la instancia, no solo localhost.
    app.run(host="0.0.0.0", port=8000)
