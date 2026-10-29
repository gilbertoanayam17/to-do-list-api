import json
import os

import boto3
import pymysql
from flask import Flask, jsonify, request

app = Flask(__name__)


def load_db_credentials():
    # Las credenciales viven en Secrets Manager, no en el código.
    # boto3 se autentica con el rol IAM de la instancia (instance profile).
    client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    secret = client.get_secret_value(SecretId=os.environ["DB_SECRET_ID"])
    return json.loads(secret["SecretString"])


DB = load_db_credentials()


def get_connection():
    return pymysql.connect(
        host=DB["host"],
        port=int(DB["port"]),
        user=DB["username"],
        password=DB["password"],
        database=DB["dbname"],
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


def init_db():
    with get_connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id INT AUTO_INCREMENT PRIMARY KEY,
                tarea VARCHAR(255) NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )


init_db()


@app.get("/tasks")
def list_tasks():
    with get_connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT id, tarea FROM tasks ORDER BY id")
        return jsonify(cur.fetchall())


@app.post("/tasks")
def add_task():
    body = request.get_json(silent=True) or {}
    tarea = body.get("tarea")
    if not isinstance(tarea, str) or not tarea.strip():
        return jsonify({"error": "Se requiere el campo 'tarea' (texto no vacio)"}), 400
    if len(tarea.strip()) > 255:
        return jsonify({"error": "'tarea' no puede pasar de 255 caracteres"}), 400

    with get_connection() as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO tasks (tarea) VALUES (%s)", (tarea.strip(),))
        task = {"id": cur.lastrowid, "tarea": tarea.strip()}
    return jsonify(task), 201


if __name__ == "__main__":
    # 0.0.0.0 para aceptar conexiones desde fuera de la instancia, no solo localhost.
    app.run(host="0.0.0.0", port=8000)
