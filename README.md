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
