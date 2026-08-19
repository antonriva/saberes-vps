#!/bin/bash
# Crea N cursos "shell" (sin contenido) en Canvas, replicando los atributos
# (nombre, course_code, cuenta, término) de 1..N cursos fuente, vía la API REST
# de Canvas (POST /api/v1/accounts/:id/courses). No copia contenido — para eso
# se necesitaría content_migrations (course_copy_importer), fuera de alcance aquí.
#
# Uso:
#   CANVAS_URL=http://localhost:17380 \
#   API_TOKEN=xxxx \
#   SOURCE_COURSE_IDS="12,13" \
#   ACCOUNT_ID=1 \
#   TOTAL_COURSES=70 \
#   PUBLISH=true \
#   ./scripts/populate_courses.sh
#
# Mismo script sirve contra el VPS real: solo cambia CANVAS_URL y API_TOKEN.

set -euo pipefail

: "${CANVAS_URL:?Falta CANVAS_URL (ej. http://localhost:17380)}"
: "${API_TOKEN:?Falta API_TOKEN (Account > Settings > + New Access Token)}"
: "${SOURCE_COURSE_IDS:?Falta SOURCE_COURSE_IDS, ej: \"12,13\"}"
: "${ACCOUNT_ID:?Falta ACCOUNT_ID (cuenta destino donde crear los cursos)}"
TOTAL_COURSES="${TOTAL_COURSES:-70}"
PUBLISH="${PUBLISH:-false}"

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Falta '$bin'." >&2; exit 1; }
done

IFS=',' read -ra SOURCE_IDS <<< "$SOURCE_COURSE_IDS"
NUM_SOURCES=${#SOURCE_IDS[@]}
[ "$NUM_SOURCES" -ge 1 ] || { echo "SOURCE_COURSE_IDS vacío." >&2; exit 1; }

auth=(-H "Authorization: Bearer $API_TOKEN")

echo "--> Leyendo atributos de los cursos fuente..."
declare -a SRC_NAME SRC_CODE SRC_TERM
for i in "${!SOURCE_IDS[@]}"; do
  id="${SOURCE_IDS[$i]}"
  resp="$(curl -sf "${auth[@]}" "$CANVAS_URL/api/v1/courses/$id")" \
    || { echo "No se pudo leer el curso fuente $id" >&2; exit 1; }
  SRC_NAME[$i]="$(jq -r '.name' <<< "$resp")"
  SRC_CODE[$i]="$(jq -r '.course_code' <<< "$resp")"
  SRC_TERM[$i]="$(jq -r '.enrollment_term_id' <<< "$resp")"
  echo "    [$id] name=${SRC_NAME[$i]} code=${SRC_CODE[$i]} term=${SRC_TERM[$i]}"
done

per_source=$(( TOTAL_COURSES / NUM_SOURCES ))
extra=$(( TOTAL_COURSES % NUM_SOURCES ))

echo "--> Creando $TOTAL_COURSES cursos en la cuenta $ACCOUNT_ID (publish=$PUBLISH)..."
created=0
for i in "${!SOURCE_IDS[@]}"; do
  count=$per_source
  [ "$i" -lt "$extra" ] && count=$(( count + 1 ))

  for n in $(seq -w 1 "$count"); do
    name="${SRC_NAME[$i]} $n"
    code="${SRC_CODE[$i]}-$n"
    sis_id="REPLICA-${SOURCE_IDS[$i]}-$n"

    # Idempotencia: si ya existe un curso con este sis_course_id, se salta.
    if curl -sf "${auth[@]}" "$CANVAS_URL/api/v1/courses/sis_course_id:$sis_id" >/dev/null 2>&1; then
      echo "    ya existe: $sis_id, salto"
      continue
    fi

    resp="$(curl -sf "${auth[@]}" -X POST "$CANVAS_URL/api/v1/accounts/$ACCOUNT_ID/courses" \
      --data-urlencode "course[name]=$name" \
      --data-urlencode "course[course_code]=$code" \
      --data-urlencode "course[sis_course_id]=$sis_id" \
      --data-urlencode "course[term_id]=${SRC_TERM[$i]}" \
      --data-urlencode "offer=$PUBLISH")"

    new_id="$(jq -r '.id' <<< "$resp")"
    echo "    creado: $name (id=$new_id, sis=$sis_id)"
    created=$(( created + 1 ))
  done
done

echo "--> Listo. $created cursos creados."
