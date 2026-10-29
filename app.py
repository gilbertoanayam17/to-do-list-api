from flask import Flask, jsonify, request

app = Flask(__name__)

# Las tareas viven en memoria: se pierden al reiniciar el proceso.
tasks = []


@app.get("/tasks")
def list_tasks():
    return jsonify(tasks)


@app.post("/tasks")
def add_task():
    body = request.get_json(silent=True) or {}
    tarea = body.get("tarea")
    if not isinstance(tarea, str) or not tarea.strip():
        return jsonify({"error": "Se requiere el campo 'tarea' (texto no vacio)"}), 400

    task = {"id": len(tasks) + 1, "tarea": tarea.strip()}
    tasks.append(task)
    return jsonify(task), 201


if __name__ == "__main__":
    # 0.0.0.0 para aceptar conexiones desde fuera de la instancia, no solo localhost.
    app.run(host="0.0.0.0", port=8000)
