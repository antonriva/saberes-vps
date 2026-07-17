# Canvas LMS — despliegue con Docker Compose

Stack de Canvas LMS (nginx + web + jobs + rce + postgres + redis) pensado
para levantarse igual en cualquier servidor Rocky Linux con Docker. Todo el
toolchain de Canvas (Ruby, Node, Yarn) vive **dentro** de la imagen — el host
solo necesita Docker.

## Requisitos del servidor (Rocky Linux)

```bash
sudo dnf install -y dnf-plugins-core gettext git
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # cerrar sesión y volver a entrar
```

## Clonar

```bash
git clone --recurse-submodules <url-de-este-repo>
cd canvas-deploy
```

Si ya clonaste sin `--recurse-submodules`:
```bash
git submodule update --init --recursive
```

## Configurar

```bash
cp .env.example .env
```
Edita `.env`:
- `CANVAS_DOMAIN` — dominio o IP por la que vas a acceder (`localhost` en tu propia máquina, o la IP/dominio real del servidor).
- `HOST_PORT` — puerto donde nginx va a escuchar.
- `POSTGRES_PASSWORD`, `CANVAS_LMS_ADMIN_EMAIL`, `CANVAS_LMS_ADMIN_PASSWORD`, `CANVAS_LMS_ACCOUNT_NAME`.

`.env` no se commitea — cada servidor tiene el suyo.

## Abrir el puerto (firewalld)

Rocky Linux trae `firewalld` activo por default en instalaciones normales
(a diferencia de un entorno WSL2, donde normalmente no corre). Si tu server
tiene `firewalld` activo, abre el puerto que pusiste en `HOST_PORT`:

```bash
sudo firewall-cmd --permanent --add-port=$(grep HOST_PORT .env | cut -d= -f2)/tcp
sudo firewall-cmd --reload
```

(Si estás desplegando dentro de WSL2 en vez de un Rocky "de verdad", el
bloqueo típico no es `firewalld` sino el **Firewall de Windows** del lado del
host — ver la sección de Troubleshooting.)

## Levantar todo

```bash
./setup.sh
```

Esto hace, en orden: genera `canvas-lms/config/*.yml` a partir de las
plantillas en `canvas-config/*.tmpl` (sustituyendo las variables de `.env`),
construye la imagen, levanta `postgres`/`redis`, corre `bundle install` +
`yarn install` + compilación de assets dentro del contenedor, crea la base
de datos y la cuenta admin, y finalmente levanta el stack completo.

Puede tardar bastante la primera vez (descarga de gemas/paquetes JS y
compilación de assets). Corridas siguientes son mucho más rápidas porque
`bundle`/`node_modules`/caché de yarn quedan en volúmenes Docker persistentes
(`canvas_bundle`, `canvas_gems`, `canvas_yarn_cache`, `canvas_node_modules`).

## Verificar

```bash
docker compose ps
curl -I http://localhost:$(grep HOST_PORT .env | cut -d= -f2)/
```
Un `302` hacia `/login` confirma que nginx y Rails están respondiendo.

Entra desde el navegador a `http://<CANVAS_DOMAIN>:<HOST_PORT>/` con el
email/contraseña admin definidos en `.env`.

## Estructura del repo

```
docker-compose.yml       # servicios: nginx, web, jobs, rce, postgres, redis
nginx/canvas.conf        # proxy hacia el contenedor web
canvas-config/*.tmpl     # plantillas de config/*.yml de canvas-lms (envsubst)
setup.sh                 # automatiza todo el proceso de instalación
canvas-lms/              # submódulo git -> instructure/canvas-lms (pinned)
.env / .env.example      # secretos y config por servidor (no versionado)
```

### Por qué `canvas-config/*.tmpl` y no `canvas-lms/config/*.yml` directamente

`canvas-lms/.gitignore` ignora `config/*.yml` (son configs con secretos por
diseño). Como acá `canvas-lms/` es un submódulo de solo lectura, esos
archivos generados **no se pueden versionar ahí**. `canvas-config/*.tmpl`
vive en este repo, sí se versiona, y `setup.sh` los renderiza hacia
`canvas-lms/config/` en cada setup.

## Notas de compatibilidad ya resueltas en las plantillas

Estos son bugs reales con los que nos topamos armando este stack por primera
vez — ya están corregidos en `canvas-config/*.tmpl`, documentados acá para
que no se pierdan si alguien las vuelve a tocar:

- **`redis.yml`**: la clave correcta es `url:`, no `servers:` (con
  `servers:` revienta con `ArgumentError: unknown keyword: :servers` al
  construir el cliente de Redis).
- **`security.yml`**: necesita el bloque `production: &default` presente
  (aunque no se use en dev) porque `development`/`test` lo referencian con
  `<<: *default` — sin el ancla, YAML falla con `Psych::AnchorNotDefined`.
- **`database.yml`**: necesita `username: canvas` explícito — sin eso el
  adapter de Postgres usa el usuario del sistema del contenedor (`docker`),
  que no existe en la base de datos.
- **`domain.yml`**: el `domain:` debe incluir el puerto
  (`localhost:17380`, no solo `localhost`) — Canvas arma sus URLs de
  redirect a partir de este valor.
- **`nginx/canvas.conf`**: usa `proxy_set_header Host $http_host;`, no
  `$host` — la variable `$host` de nginx excluye el puerto por diseño, lo
  que hacía que todos los redirects de Canvas perdieran el puerto
  configurado.
- **`NODE_OPTIONS=--dns-result-order=ipv4first`** en `docker-compose.yml`:
  el contenedor no tiene ruta IPv6, pero varios hosts (registry de yarn,
  etc.) devuelven direcciones IPv6 primero, causando `ENETUNREACH` en bucle
  sin esto.
- **`./canvas-lms:/usr/src/app:z`** en los bind mounts: el sufijo `:z`
  relabela el directorio del host para que el contenedor pueda leer/escribir
  ahí bajo SELinux enforcing (default en Rocky Linux real). Es un no-op
  inofensivo si SELinux está deshabilitado.
- **`canvas-config/vault_contents.yml.tmpl`**: sin este archivo, Canvas no
  tiene cómo firmar/encriptar el JWT que el editor de contenido enriquecido
  (RCE) necesita para autenticar al usuario. `CanvasSecurity::ServicesJwt`
  (con `symmetric: true`, ya usado tal cual en `rich_content.rb` — no hace
  falta tocar código Ruby) lee `canvas_security.encryption_secret`/
  `signing_secret` desde `Rails.application.credentials`, que sin un Vault
  real corriendo se completan leyendo `config/vault_contents.yml` (ver
  `Canvas::Vault::FileClient`). Sin ese archivo esos valores son `nil`, y
  Canvas termina mandando el string literal `"InvalidJwtKey"` como JWT. La
  plantilla rellena `encryption_secret`/`signing_secret` con
  `RCE_ECOSYSTEM_KEY`/`RCE_ECOSYSTEM_SECRET` — deben ser el mismo valor que
  el contenedor `rce` recibe como `ECOSYSTEM_KEY`/`ECOSYSTEM_SECRET`, o el
  RCE no puede desencriptar/verificar lo que Canvas firmó.
- **`build.args.USER_ID`** en `web`/`jobs`: el usuario interno del
  contenedor (`docker`) tiene UID `9999` por defecto, distinto al UID del
  usuario que hizo `git clone` en el host. Como `canvas-lms/` está montado
  como bind mount, sin esto el contenedor no puede escribir `Gemfile.lock`,
  `log/`, `tmp/`, etc. (permission denied), aunque el `.gitignore` de
  canvas-lms nunca lo va a mostrar como "sucio". `setup.sh` ya pasa
  `USER_ID=$(id -u)` automáticamente; el Dockerfile remapea el usuario
  `docker` a ese UID en build time. Si reconstruyes la imagen a mano, hazlo
  con `USER_ID=$(id -u) docker compose build` — sin eso vuelve al UID 9999
  por defecto.

## Troubleshooting

- **No carga nada en el puerto (`ERR_CONNECTION_REFUSED` o timeout) en un
  Rocky Linux real**: revisa `firewalld` (ver sección de arriba). Confirma
  primero que responde *dentro* del servidor (`curl -I
  http://localhost:$HOST_PORT/`) antes de sospechar de Docker — si eso ya
  da `302`, el problema es de firewall/red, no de la app.
- **Estás desplegando dentro de WSL2 (Rocky Linux corriendo en Windows) y no
  carga desde el navegador de Windows aunque `curl` adentro de WSL sí
  responda**: eso no es `firewalld`, es el **Firewall de Windows**
  bloqueando la interfaz de red de WSL (típico si WSL está en modo de red
  "mirrored"). Se abre desde una PowerShell **de administrador** en Windows:
  ```powershell
  New-NetFirewallRule -DisplayName "Canvas WSL $HOST_PORT" -Direction Inbound -LocalPort $HOST_PORT -Protocol TCP -Action Allow
  ```
- **Los redirects de Canvas van al puerto equivocado (te manda a
  `http://localhost/login` sin puerto)**: revisa que `CANVAS_DOMAIN`/
  `HOST_PORT` en `.env` coincidan con por dónde estás entrando de verdad, y
  que `nginx/canvas.conf` siga usando `$http_host` (no `$host`) — ver nota
  arriba.
- **`Permission denied` dentro del contenedor al leer/escribir en
  `/usr/src/app`** (p. ej. `bundle install` no puede escribir
  `Gemfile.lock`, o Rails no puede crear archivos en `log/`/`tmp/`): la
  causa más común es **UID mismatch**, no SELinux — confirma que hiciste
  build con `USER_ID=$(id -u)` (ver nota arriba; `setup.sh` ya lo hace
  solo). No lo arregles con `chmod 666`/`chmod -R 777` — es un parche que
  hay que repetir cada vez y deja los archivos escribibles por cualquiera;
  el build arg lo resuelve de raíz y de forma permanente. Si después de
  rebuildear con `USER_ID` correcto sigue fallando, ahí sí puede ser
  SELinux — confirma que los volumes tengan el sufijo `:z` (ya aplicado), o
  descarta con `sudo setenforce 0` temporalmente para diagnosticar.
- **`Permission denied` en algo dentro de `/home/docker/.gem/...`
  (ej. `.../bin/crystalball.lock`), no en `/usr/src/app`**: distinto del
  punto anterior — este es un **volumen nombrado** (`canvas_gems`,
  `canvas_bundle`, `canvas_yarn_cache`, `canvas_node_modules`,
  `canvas_packs`), no el bind mount. Pasa cuando un intento anterior falló
  a medias con un `USER_ID` distinto (o sin él) y dejó archivos ahí dueños
  de un UID viejo; como los volúmenes persisten entre intentos a propósito
  (para no reinstalar todo cada vez), ese resto queda bloqueando al UID
  nuevo. `setup.sh` ya normaliza el dueño de estos volúmenes como `root`
  antes de instalar en cada corrida, así que no debería repetirse — si
  corriste los pasos a mano sin pasar por `setup.sh`, hazlo tú mismo:
  ```bash
  docker compose run --rm -u root web bash -lc "
  mkdir -p /home/docker/.gem /home/docker/.bundle /home/docker/.cache/yarn /usr/src/app/node_modules /usr/src/app/public/packs
  chown -R docker:docker /home/docker/.gem /home/docker/.bundle /home/docker/.cache/yarn /usr/src/app/node_modules /usr/src/app/public/packs
  "
  ```
  Si eso tampoco alcanza, la opción nuclear es borrar esos volúmenes
  (`docker compose down` + `docker volume rm <proyecto>_canvas_gems ...`) y
  dejar que `setup.sh` los recree limpios — no se pierde nada importante,
  son solo cachés de gemas/paquetes.
- **`web` en crash-loop con `A server is already running (pid: 1, file:
  /usr/src/app/tmp/pids/server.pid)`**: quedó un `server.pid` viejo de un
  contenedor anterior que no se apagó limpio (`docker kill`, OOM, etc.).
  `rm -f canvas-lms/tmp/pids/server.pid` y reinicia — `setup.sh` ya lo hace
  automáticamente antes del `up -d` final.
- **`jobs` en crash-loop**: casi siempre es un `config/*.yml` faltante o mal
  generado. `docker compose logs jobs` te va a decir exactamente qué
  archivo no encontró o qué clave rechazó.
- **El editor de contenido enriquecido (RCE) no carga, se queda pidiendo
  sesión, o `docker compose logs rce` muestra `401`/`403` en
  `/api/session`**: el JWT que Canvas le manda al RCE no es válido. Casi
  siempre es porque falta `canvas-lms/config/vault_contents.yml` (no se
  regeneró — corré `./setup.sh` de nuevo, o a mano: `set -a; source .env;
  set +a; envsubst < canvas-config/vault_contents.yml.tmpl >
  canvas-lms/config/vault_contents.yml`, y reiniciá `web`/`jobs`), o porque
  `RCE_ECOSYSTEM_KEY`/`RCE_ECOSYSTEM_SECRET` en `.env` no coinciden en valor
  con lo que quedó rendereado ahí (si cambiaste `.env` después del setup
  inicial, hay que volver a renderizar y reiniciar). Ver la nota de
  `canvas-config/vault_contents.yml.tmpl` más arriba para el detalle
  completo.
