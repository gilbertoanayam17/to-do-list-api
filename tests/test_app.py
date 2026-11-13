from datetime import datetime

import pymysql
import pytest

import app as todo


@pytest.fixture
def metrics(monkeypatch):
    # En lugar de mandar a CloudWatch, guarda los nombres de las métricas enviadas.
    sent = []
    monkeypatch.setattr(todo, "put_metric", lambda name, value, unit: sent.append(name))
    return sent


@pytest.fixture
def client(monkeypatch, metrics):
    # La "base de datos" de las pruebas es una lista; no se toca RDS.
    tasks = []

    def fake_insert(title, done):
        tasks.append({"id": len(tasks) + 1, "title": title, "done": done})
        return len(tasks)

    monkeypatch.setattr(todo, "fetch_tasks", lambda: list(tasks))
    monkeypatch.setattr(todo, "insert_task", fake_insert)
    monkeypatch.setattr(todo, "check_db", lambda: None)
    return todo.app.test_client()


def test_get_tasks_empieza_vacio(client):
    response = client.get("/tasks")

    assert response.status_code == 200
    assert response.get_json() == []


def test_post_tasks_crea_tarea(client):
    response = client.post("/tasks", json={"title": "estudiar para el examen", "done": False})

    assert response.status_code == 201
    assert response.get_json() == {"id": 1, "title": "estudiar para el examen", "done": False}
    assert client.get("/tasks").get_json() == [{"id": 1, "title": "estudiar para el examen", "done": False}]


@pytest.mark.parametrize("body", [{}, {"title": "   "}, {"title": "x" * 256}, {"title": "ok", "done": "no"}])
def test_post_tasks_invalida_regresa_400(client, body):
    response = client.post("/tasks", json=body)

    assert response.status_code == 400
    assert client.get("/tasks").get_json() == []


def test_version_viene_de_variable_de_ambiente(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v1.2.3")

    assert client.get("/version").get_json() == {"version": "v1.2.3"}


def test_health_ok(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v1.2.3")

    response = client.get("/health")

    body = response.get_json()
    assert response.status_code == 200
    assert body["database"] == "OK"
    assert body["version"] == "v1.2.3"
    assert datetime.fromisoformat(body["timestamp"])


def test_health_regresa_503_si_falla_la_bd(client, monkeypatch):
    def bd_caida():
        raise pymysql.err.OperationalError(2003, "RDS no responde")

    monkeypatch.setattr(todo, "check_db", bd_caida)

    response = client.get("/health")

    assert response.status_code == 503
    assert response.get_json()["database"] == "FAIL"


def test_error_de_rds_manda_metrica(metrics, monkeypatch):
    def bd_caida():
        raise pymysql.err.OperationalError(2003, "RDS no responde")

    monkeypatch.setattr(todo, "get_connection", bd_caida)

    response = todo.app.test_client().get("/tasks")

    assert response.status_code == 500
    assert "DatabaseErrors" in metrics


def test_cada_peticion_manda_latencia(client, metrics):
    client.get("/tasks")

    assert metrics == ["Latency"]
