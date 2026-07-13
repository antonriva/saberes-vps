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

# El contenedor escribe en canvas-lms/ (bind mount) como el usuario "docker"
# (UID 9999 por defecto en la imagen). Si no coincide con el dueño real de
# los archivos (el usuario que hizo git clone), Rails/Bundler no pueden
# escribir Gemfile.lock, log/, tmp/, etc. Pasamos nuestro propio UID como
# build arg para que el Dockerfile remapee el usuario interno y coincida.
export USER_ID="$(id -u)"

echo "--> Inicializando submódulo canvas-lms..."
git submodule update --init --recursive

echo "--> Generando config/*.yml de canvas-lms a partir de canvas-config/*.tmpl..."
mkdir -p canvas-lms/config
for tmpl in canvas-config/*.tmpl; do
  out="canvas-lms/config/$(basename "${tmpl%.tmpl}")"
  envsubst < "$tmpl" > "$out"
done

echo "--> Creando directorios que Rails necesita en runtime (log/tmp)..."
mkdir -p canvas-lms/log canvas-lms/tmp/cache canvas-lms/tmp/pids canvas-lms/tmp/sockets

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
# Por si quedó un tmp/pids/server.pid de una corrida anterior (container
# matado sin apagado limpio): Rails se niega a arrancar si lo ve.
rm -f canvas-lms/tmp/pids/server.pid
docker compose up -d

echo ""
echo "Listo. Canvas debería responder en: http://${CANVAS_DOMAIN}:${HOST_PORT}/"
echo "Admin: ${CANVAS_LMS_ADMIN_EMAIL}"
