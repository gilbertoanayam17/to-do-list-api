import json
import os
import time
from contextlib import contextmanager
from datetime import datetime, timezone

import boto3
import pymysql
from flask import Flask, g, jsonify, request

app = Flask(__name__)

REGION = os.environ.get("AWS_REGION", "us-east-1")
cloudwatch = boto3.client("cloudwatch", region_name=REGION)

# Las credenciales de la BD se leen de Secrets Manager en la primera conexión
# (no al importar, así las pruebas no necesitan AWS).
DB = None
TABLE_READY = False


def load_db_credentials():
    secrets = boto3.client("secretsmanager", region_name=REGION)
    secret = secrets.get_secret_value(SecretId=os.environ["DB_SECRET_ID"])
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
        connect_timeout=5,
    )
    if not TABLE_READY:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS tasks (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    title VARCHAR(255) NOT NULL,
                    done BOOLEAN NOT NULL DEFAULT FALSE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
        TABLE_READY = True
    return conn


def put_metric(name, value, unit):
    # Si CloudWatch falla no tumbamos la API, solo queda en el log.
    try:
        cloudwatch.put_metric_data(
            Namespace="ToDoListApi",
            MetricData=[{"MetricName": name, "Value": value, "Unit": unit}],
        )
    except Exception:
        app.logger.warning("No se pudo mandar la métrica %s", name, exc_info=True)


@contextmanager
def db_cursor():
    # Todas las lecturas y escrituras a RDS pasan por aquí para contar los errores.
    try:
        with get_connection() as conn, conn.cursor() as cur:
            yield cur
    except Exception:
        put_metric("DatabaseErrors", 1, "Count")
        raise


def fetch_tasks():
    with db_cursor() as cur:
        cur.execute("SELECT id, title, done FROM tasks ORDER BY id")
        return [{**task, "done": bool(task["done"])} for task in cur.fetchall()]


def insert_task(title, done):
    with db_cursor() as cur:
        cur.execute("INSERT INTO tasks (title, done) VALUES (%s, %s)", (title, done))
        return cur.lastrowid


def check_db():
    with db_cursor() as cur:
        cur.execute("SELECT 1")


def app_version():
    # En la EC2 viene de /etc/todo.env; el workflow de deploy la cambia con cada release.
    return os.environ.get("APP_VERSION", "dev")


@app.before_request
def start_timer():
    g.start = time.perf_counter()


@app.after_request
def send_latency(response):
    latency_ms = (time.perf_counter() - g.start) * 1000
    put_metric("Latency", latency_ms, "Milliseconds")
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
        database = "FAIL"

    body = {
        "status": database,
        "database": database,
        "version": app_version(),
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    # 503 cuando la BD falla, para que el health check de GitHub Actions lo detecte.
    return jsonify(body), 200 if database == "OK" else 503


@app.get("/tasks")
def list_tasks():
    return jsonify(fetch_tasks())


@app.post("/tasks")
def add_task():
    body = request.get_json(silent=True) or {}
    title = body.get("title")
    done = body.get("done", False)

    if not isinstance(title, str) or not title.strip() or len(title.strip()) > 255:
        return jsonify({"error": "'title' es obligatorio (texto de 1 a 255 caracteres)"}), 400
    if not isinstance(done, bool):
        return jsonify({"error": "'done' debe ser true o false"}), 400

    title = title.strip()
    task_id = insert_task(title, done)
    return jsonify({"id": task_id, "title": title, "done": done}), 201


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
