#!/bin/bash
# Log completo en /var/log/user-data.log para depurar con SSH.
exec > >(tee /var/log/user-data.log) 2>&1
set -euxo pipefail

APP_DIR=/opt/todo

apt-get update -y
apt-get install -y git python3-venv mysql-client jq

git clone --branch "${repo_branch}" "${repo_url}" "$APP_DIR"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
chown -R ubuntu:ubuntu "$APP_DIR"

# systemd arranca la app en cada boot y la reinicia si se cae.
# La app solo conoce el nombre del secreto; las credenciales las lee de Secrets Manager.
# Con las tareas en la BD ya se pueden usar varios workers.
cat > /etc/systemd/system/todo.service <<EOF
[Unit]
Description=to-do-list API
After=network-online.target
Wants=network-online.target

[Service]
User=ubuntu
WorkingDirectory=$APP_DIR
Environment=AWS_REGION=${region}
Environment=DB_SECRET_ID=${db_secret_id}
ExecStart=$APP_DIR/venv/bin/gunicorn --bind 0.0.0.0:${app_port} --workers 2 app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Atajo para abrir la BD: `todo-db` (shell) o `todo-db -e "SELECT * FROM tasks;"`
cat > /usr/local/bin/todo-db <<'EOF'
#!/bin/bash
SECRET=$(aws secretsmanager get-secret-value --region ${region} \
  --secret-id ${db_secret_id} --query SecretString --output text)
export MYSQL_PWD=$(jq -r .password <<<"$SECRET")
exec mysql -h "$(jq -r .host <<<"$SECRET")" -P "$(jq -r .port <<<"$SECRET")" \
  -u "$(jq -r .username <<<"$SECRET")" "$(jq -r .dbname <<<"$SECRET")" "$@"
EOF
chmod +x /usr/local/bin/todo-db

systemctl daemon-reload
systemctl enable --now todo.service

# AWS CLI para `todo-db`; va al final para no retrasar el arranque de la app.
snap install aws-cli --classic
