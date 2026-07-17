#!/bin/bash
# Antes es necesario generar el .env local
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

for var in RCE_ECOSYSTEM_KEY RCE_ECOSYSTEM_SECRET; do
  len=$(printf '%s' "${!var}" | wc -c)
  [ "$len" -eq 32 ] || { echo "'$var' debe medir exactamente 32 bytes (mide $len). Genera uno con: openssl rand -hex 16" >&2; exit 1; }
done

export USER_ID="$(id -u)"

echo "--> Inicializando submódulo canvas-lms..."
git submodule update --init --recursive

if [ -f canvas-lms/.git ]; then
  echo "--> Embebiendo el .git del submódulo dentro de canvas-lms/ (para que el bind mount sea autocontenido)..."
  git_dir_rel="$(sed -n 's/^gitdir: //p' canvas-lms/.git)"
  git_dir_abs="$(cd canvas-lms && cd "$git_dir_rel" && pwd)"
  rm canvas-lms/.git
  mv "$git_dir_abs" canvas-lms/.git
  sed -i '/^\s*worktree = /d' canvas-lms/.git/config
fi

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

echo "--> Normalizando permisos en volúmenes persistentes..."
docker compose run --rm -u root web bash -lc "
mkdir -p /home/docker/.gem /home/docker/.bundle /home/docker/.cache/yarn /usr/src/app/node_modules /usr/src/app/public/packs
chown -R docker:docker /home/docker/.gem /home/docker/.bundle /home/docker/.cache/yarn /usr/src/app/node_modules /usr/src/app/public/packs
"

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
rm -f canvas-lms/tmp/pids/server.pid
docker compose up -d

echo ""
echo "Listo. Canvas debería responder en: http://${CANVAS_DOMAIN}:${HOST_PORT}/"
echo "Admin: ${CANVAS_LMS_ADMIN_EMAIL}"
