# to-do-list-api

API sencilla de to-do list en Python (Flask).

| Método | Ruta     | Descripción                     |
|--------|----------|---------------------------------|
| GET    | `/tasks` | Regresa la lista de tareas      |
| POST   | `/tasks` | Agrega una tarea `{"tarea": "..."}` |

## Correr en local

```bash
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python app.py                    # escucha en http://0.0.0.0:8000
```

```bash
curl http://localhost:8000/tasks
curl -X POST http://localhost:8000/tasks \
  -H "Content-Type: application/json" \
  -d '{"tarea": "resolver actividad en equipo"}'
```

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
