#!/bin/bash
# Corre EN LA EC2 (como root): descarga el zip de un release de GitHub, lo instala en
# /opt/todo/app y reinicia la app. Si la nueva versión no responde, regresa a la anterior.
# Uso: deploy.sh <owner/repo> <tag>   (el workflow Deploy lo manda por SSH)
set -euo pipefail

REPO=$1
TAG=$2
APP_DIR=/opt/todo
PORT=8000
ZIP_URL="https://github.com/$REPO/releases/download/$TAG/to-do-list-api-$TAG.zip"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Descargando $ZIP_URL"
curl -fsSL "$ZIP_URL" -o "$TMP/release.zip"
unzip -q "$TMP/release.zip" -d "$TMP"
"$APP_DIR/venv/bin/pip" install -q -r "$TMP/to-do-list-api/requirements.txt"

PREV_VERSION=$(sed -n 's/^APP_VERSION=//p' /etc/todo.env)
rm -rf "$APP_DIR/app.prev"
mv "$APP_DIR/app" "$APP_DIR/app.prev"
mv "$TMP/to-do-list-api" "$APP_DIR/app"
chown -R ubuntu:ubuntu "$APP_DIR/app" "$APP_DIR/venv"
echo "APP_VERSION=$TAG" > /etc/todo.env
systemctl restart todo

for _ in $(seq 1 15); do
  if [[ "$(curl -fs "localhost:$PORT/version")" == *"\"$TAG\""* ]]; then
    echo "Desplegado $TAG (antes: $PREV_VERSION)"
    exit 0
  fi
  sleep 2
done

echo "La versión $TAG no respondió; regresando a $PREV_VERSION" >&2
journalctl -u todo -n 30 --no-pager >&2
rm -rf "$APP_DIR/app.failed"
mv "$APP_DIR/app" "$APP_DIR/app.failed"
mv "$APP_DIR/app.prev" "$APP_DIR/app"
echo "APP_VERSION=$PREV_VERSION" > /etc/todo.env
systemctl restart todo
exit 1
