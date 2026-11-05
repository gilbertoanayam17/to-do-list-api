from datetime import datetime

import pytest

import app as todo


@pytest.fixture
def client(monkeypatch):
    # Reemplaza la capa de base de datos por una lista: las pruebas no tocan RDS ni AWS.
    tasks = []

    def fake_insert(tarea):
        tasks.append({"id": len(tasks) + 1, "tarea": tarea})
        return len(tasks)

    monkeypatch.setattr(todo, "fetch_tasks", lambda: list(tasks))
    monkeypatch.setattr(todo, "insert_task", fake_insert)
    monkeypatch.setattr(todo, "check_db", lambda: None)
    return todo.app.test_client()


def test_get_tasks_regresa_lista_vacia(client):
    response = client.get("/tasks")

    assert response.status_code == 200
    assert response.get_json() == []


def test_post_tasks_agrega_tarea(client):
    response = client.post("/tasks", json={"tarea": "  resolver actividad en equipo  "})

    assert response.status_code == 201
    assert response.get_json() == {"id": 1, "tarea": "resolver actividad en equipo"}
    assert client.get("/tasks").get_json() == [{"id": 1, "tarea": "resolver actividad en equipo"}]


@pytest.mark.parametrize("body", [{}, {"tarea": ""}, {"tarea": "   "}, {"tarea": 123}, {"tarea": "x" * 256}])
def test_post_tasks_invalida_regresa_400(client, body):
    response = client.post("/tasks", json=body)

    assert response.status_code == 400
    assert "error" in response.get_json()
    assert client.get("/tasks").get_json() == []


def test_version_lee_variable_de_ambiente(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v1.2.3")

    response = client.get("/version")

    assert response.status_code == 200
    assert response.get_json() == {"version": "v1.2.3"}


def test_health_ok_con_version_y_timestamp(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v1.2.3")

    response = client.get("/health")

    assert response.status_code == 200
    body = response.get_json()
    assert body["status"] == "OK"
    assert body["database"] == "OK"
    assert body["version"] == "v1.2.3"
    assert datetime.fromisoformat(body["timestamp"]).tzinfo is not None


def test_health_regresa_503_si_falla_la_bd(client, monkeypatch):
    def db_caida():
        raise ConnectionError("RDS no responde")

    monkeypatch.setattr(todo, "check_db", db_caida)

    response = client.get("/health")

    assert response.status_code == 503
    assert response.get_json()["status"] == "FAIL"
    assert response.get_json()["database"] == "FAIL"
