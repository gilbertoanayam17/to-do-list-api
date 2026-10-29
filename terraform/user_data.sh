#!/bin/bash
# Log completo en /var/log/user-data.log para depurar con SSH.
exec > >(tee /var/log/user-data.log) 2>&1
set -euxo pipefail

APP_DIR=/opt/todo

apt-get update -y
apt-get install -y git python3-venv

git clone --branch "${repo_branch}" "${repo_url}" "$APP_DIR"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
chown -R ubuntu:ubuntu "$APP_DIR"

# systemd arranca la app en cada boot y la reinicia si se cae.
# Un solo worker: con tareas en memoria, cada worker tendría su propia lista.
cat > /etc/systemd/system/todo.service <<EOF
[Unit]
Description=to-do-list API
After=network-online.target
Wants=network-online.target

[Service]
User=ubuntu
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn --bind 0.0.0.0:${app_port} --workers 1 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now todo.service
