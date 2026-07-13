#!/bin/bash
# Setup end-to-end de Canvas LMS via Docker Compose, pensado para correr una
# sola vez en un servidor Rocky Linux limpio (con Docker Engine + compose
# plugin ya instalados). Ver README.md para el detalle de cada paso.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for bin in docker git envsubst; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Falta '$bin'. En Rocky Linux: sudo dnf install -y $([ "$bin" = envsubst ] && echo gettext || echo "$bin")" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "Falta el plugin 'docker compose'." >&2; exit 1; }

if [ ! -f .env ]; then
  echo "No existe .env — copiando .env.example. EDÍTALO antes de continuar (contraseñas, dominio, puerto)." >&2
  cp .env.example .env
  exit 1
fi
set -a
source .env
set +a

echo "--> Inicializando submódulo canvas-lms..."
git submodule update --init --recursive

echo "--> Generando config/*.yml de canvas-lms a partir de canvas-config/*.tmpl..."
mkdir -p canvas-lms/config
for tmpl in canvas-config/*.tmpl; do
  out="canvas-lms/config/$(basename "${tmpl%.tmpl}")"
  envsubst < "$tmpl" > "$out"
done

echo "--> Build de la imagen (Ruby/Node/Yarn quedan dentro del contenedor, no en el host)..."
docker compose build

echo "--> Levantando postgres y redis..."
docker compose up -d postgres redis

echo "--> Instalando gemas, dependencias JS y compilando assets (puede tardar varios minutos)..."
docker compose run --rm web bash -lc "
set -e
bundle config --global build.nokogiri --use-system-libraries
bundle config --global build.ffi --enable-system-libffi
mkdir -p /home/docker/.bundle
bundle install --jobs \$(nproc)
yarn install || yarn install --network-concurrency 1
bundle exec rails canvas:compile_assets_dev
"

echo "--> Creando base de datos y cuenta admin..."
docker compose run --rm web bundle exec rake db:create db:initial_setup

echo "--> Levantando el stack completo..."
docker compose up -d

echo ""
echo "Listo. Canvas debería responder en: http://${CANVAS_DOMAIN}:${HOST_PORT}/"
echo "Admin: ${CANVAS_LMS_ADMIN_EMAIL}"
